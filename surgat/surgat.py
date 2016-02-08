from smtpd import SMTPServer
import pprint
import smtplib
import os
import Queue
from threading import Thread, Lock
import logging

from connector import SAConnector


class SurgatMailServer(SMTPServer):
    MAX_BACKLOG = 5

    def __init__(self, cfg_dict):
        print(cfg_dict['local'])
        SMTPServer.__init__(self, cfg_dict['local'], None)
        self.config = cfg_dict
        self.queue = Queue.Queue(cfg_dict['threads'] * self.MAX_BACKLOG)
        self.running = False
        self.store_lock = Lock()

    def process_message(self, peer, mailfrom, rcpttos, data):
        print("Received a message for processing")
        for addr in rcpttos:
            self.queue.put([peer, mailfrom, addr, data])

    def start(self):
        if self.running is True:
            return
        self.running = True

        if 'store_directory' in self.config:
            if not os.path.isabs(self.config['store_directory']):
                self.config['store_directory'] = os.path.join(os.path.abspath(os.path.dirname(self.config['cfg_fn'])),
                                                              self.config['store_directory'])
                print("Store Directory set to {}".format(self.config['store_directory']))
            if not os.path.exists(self.config['store_directory']):
                os.makedirs(self.config['store_directory'])

        for n in range(self.config['threads']):
            thd = Thread(target=self.message_checker)
            thd.daemon = True
            thd.start()
        print("{} thread(s) started...".format(self.config['threads']))

    def store_msg(self, data):
        if 'store_directory' not in self.config:
            return
        self.store_lock.acquire()
        n = len(os.listdir(self.config['store_directory']))
        fn = os.path.join(self.config['store_directory'], "mail_{}.eml".format(n + 1))
        with open(fn, "wb") as fh:
            fh.write("{}\r\n".format(data))
        self.store_lock.release()

    def message_checker(self):
        """ Run as a thread... """
        spam_opts = self.config.get('spamd', {})

        while self.running is True:
            try:
                msg = self.queue.get(True, 10)
            except Queue.Empty:
                continue

            self.queue.task_done()
            print("Processing {} byte message from {} to {}".format(len(msg[3]), msg[1], msg[2]))

            self.store_msg(msg[3])

            spam_opts['user'] = msg[2]
            cx = SAConnector(**spam_opts)
            body = msg[3]

            if cx.check_ping():
                rv = cx.check(msg[3])
                pprint.pprint(rv)

                if rv.get('isspam', False) is True:
                    if rv.get('score') >= self.config['kill_level']:
                        print("Dropping message to {} from {} due score of {}".format(msg[2], msg[1], rv.get("score")))
                        continue
                    # log rules here?

                if len(rv.get('headers', [])) > 0:
                    body = "\r\n".join(rv.get('headers', [])) + "\r\n" + body
            else:
                if self.config.get('forward_on_error', False) is False:
                    print("Unable to connect to spamd, skipping this message...")
                    continue

            print(body)
            server = smtplib.SMTP(*self.config['forward'])
            server.sendmail(msg[1], msg[2], body)
            server.quit()
