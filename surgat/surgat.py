import logging
from smtpd import SMTPServer
import smtplib
import os
import Queue
import threading
from glob import glob

from datetime import datetime

from connector import SAConnector

STORE_PREFIX_FORMAT = '%Y%m%d_'
logger = logging.getLogger('surgat')


class SurgatMailServer(SMTPServer):
    MAX_BACKLOG = 5

    def __init__(self, cfg_dict):
        SMTPServer.__init__(self, cfg_dict['local'], None)
        self.config = cfg_dict
        self.queue = Queue.Queue(cfg_dict['threads'] * self.MAX_BACKLOG)
        self.running = False
        self.store_lock = threading.Lock()
        self.store_prefix = datetime.today().strftime(STORE_PREFIX_FORMAT)
        self.store_sequence = 0

    def process_message(self, peer, mailfrom, rcpttos, data):
        logger.debug("Received a message for processing")
        for addr in rcpttos:
            self.queue.put([peer, mailfrom, addr, data])

    def start(self):
        if self.running is True:
            return
        self.running = True
        self.check_store()

        for n in range(self.config['threads']):
            thd = threading.Thread(target=self.message_checker, args=(n,))
            thd.daemon = True
            thd.start()
        logger.debug("{} thread(s) started...".format(self.config['threads']))

    def check_store(self):
        if 'store_directory' not in self.config:
            return
        _dir = self.config['store_directory']
        logger.debug("Store Directory set to {}".format(_dir))
        if not os.path.exists(_dir):
            os.makedirs(_dir)
        existing = glob(_dir + "/{}*".format(self.store_prefix))
        if len(existing) > 0:
            last, ext = os.path.splitext(os.path.basename(sorted(existing)[-1]))
            self.store_sequence = int(last[len(self.store_prefix):]) + 1
            logger.debug("Found existing store files for today, updating store sequence to {}".
                         format(self.store_sequence))
        self.config['store_directory'] = _dir

    def store_msg(self, data, processed=False, filtered=False):
        if 'store_directory' not in self.config:
            return
        self.store_lock.acquire()
        prefix = datetime.today().strftime(STORE_PREFIX_FORMAT)
        if prefix != self.store_prefix:
            self.store_sequence = 0
            self.store_prefix = prefix
        if (processed or filtered) is False:
            ext = '.eml'
        elif processed:
            ext = '.txt'
        elif filtered:
            ext = '.saved'
        fn = os.path.join(self.config['store_directory'], "{}{}{}".format(prefix, self.store_sequence, ext))
        self.store_sequence += 1
        with open(fn, "wb") as fh:
            fh.write("{}\r\n".format(data))
        self.store_lock.release()

    def is_filtered(self, spam, score, fromaddr):
        if self.config.get('do_filter', False) is False:
            return False
        if spam:
            return True
        if score >= self.config.get('filter_above', 100):
            return True
        if fromaddr in self.config.get('filter_addresses', []):
            return True
        return False

    def message_checker(self, id):
        """ Run as a thread... """
        spam_opts = self.config.get('spamd', {})
        my_logger = logging.getLogger('surgat.worker{}'.format(id))

        while self.running is True:
            try:
                msg = self.queue.get(True, 10)
                self.queue.task_done()
            except Queue.Empty:
                continue

            my_logger.info("Processing {} byte message from {} to {}".format(len(msg[3]), msg[1], msg[2]))

            spam_opts['user'] = msg[2]
            cx = SAConnector(**spam_opts)

            body = msg[3]
            if cx.check_ping():
                rv = cx.check(msg[3])
                my_logger.debug("spamd return code = {}".format(rv.get('code')))

                if rv.get('isspam', False) is True:
                    if 'kill_level' in self.config and rv.get('score') >= self.config['kill_level']:
                        my_logger.info("Dropping message to {} from {} due score of {}".
                                       format(msg[2], msg[1], rv.get("score")))
                        continue
                    # log rules here?

                if len(rv.get('headers', [])) > 0:
                    body = "\r\n".join(rv.get('headers', [])) + "\r\n" + body

                if self.is_filtered(rv.get('result'), rv.get('score'), msg[1]):
                    self.store_msg(body, False, True)

            else:
                if self.config.get('forward_on_error', False) is False:
                    my_logger.warn("Unable to connect to spamd, storing the message")
                    self.store_msg(msg[3])
                    continue
                else:
                    my_logger.warn("Unable to contact spamd, but forwarding message due forward_on_error setting")

            try:
                server = smtplib.SMTP(*self.config['forward'])
                server.sendmail(msg[1], msg[2], body)
                server.quit()
                my_logger.info("message to {} forwarded".format(msg[2]))
            except:
                self.store_msg(body, True)
                my_logger.warn("Unable to forward message, stored...")
