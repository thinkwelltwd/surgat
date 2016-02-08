import asyncore
from smtpd import SMTPServer
import pprint
import smtplib
import spamc
import os
import argparse
import ConfigParser
import sys
import Queue
from threading import Thread, Lock
import logging


def spamd_headers_for_message(data):
    rv = []
    for k in data.get('headers', []):
        if not k.startswith('X-Spam'):
            continue
        if not data.get('isspam', False) and k not in ['X-Spam-Status', 'X-Spam-Checker-Version']:
            print("Skipping {} as not spam...".format(k))
            continue
        rv.append('{}: {}'.format(k, data['headers'][k]))
    return rv


class SAConnector(object):
    def __init__(self, server='localhost', port=783, user=None):
        """ A connection to spamd for the prvided user. """
        self.client = spamc.SpamC(server, port, user=user)

    def check_ping(self):
        try:
            self.client.ping()
        except spamc.exceptions.SpamCError:
            return False
        return True

    def check(self, msg):
        """ Actually do the check of the message.
        :param msg: Message body to check...
        :return: {'result': True/False, 'headers': spam-headers, 'basescore': n.n, 'score': n.n}
        """
        ck = self.client.headers(msg)
        pprint.pprint(ck)
        return {'result': True if ck.get('isspam', False) else False,
                'basescore': ck.get('basescore'),
                'score': ck.get('score'),
                'headers': spamd_headers_for_message(ck)}


class SurgatMailServer(SMTPServer):
    MAX_BACKLOG = 5

    def __init__(self, cfg_dict): #localaddr, remoteaddr):
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
            server = smtplib.SMTP(self.config['forward'])
            server.sendmail(msg[1], msg[2], body)
            server.quit()


def config_dict_from_parser(cfg):
    cfg_dict = {}
    OPTS = {
        'local': [('Listen', 'hostname', 'localhost'),
                  ('Listen', 'port', 10025, 'int')],
        'forward': [('Forward', 'hostname', 'localhost'),
                    ('Forward', 'port', 10026, 'int')],
        'threads': ('General', 'threads', 5, 'int'),
        'kill_level': ('General', 'kill_level', 50, 'int'),
        'max_size': ('General', 'max_size', 10000, 'int'),
        'store_directory': ('General', 'store_directory', None),
        'forward_on_error': ('General', 'forward_on_error', False)
    }

    def get_opt_or_default(cfg, opt):
        if not cfg.has_section(opt[0]):
            return opt[2]
        if not cfg.has_option(opt[0], opt[1]):
            return opt[2]
        v = cfg.get(opt[0], opt[1])
        if len(opt) > 3 and opt[3] == 'int':
            return int(v)
        return v

    for k in OPTS:
        val = OPTS[k]
        if type(val) is list:
            cfg_dict[k] = tuple([get_opt_or_default(cfg, x) for x in val])
        else:
            cfg_dict[k] = get_opt_or_default(cfg, val)
        if cfg_dict[k] is None:
            del(cfg_dict[k])

    if cfg.has_section('Spamd'):
        cfg_dict['spamd'] = {}
        for opt in cfg.options('Spamd'):
            v = cfg.get('Spamd', opt)
            if v.isdigit():
                v = int(v)
            cfg_dict['spamd'][opt] = v

    return cfg_dict


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='surgat Spamassassin Proxy server')
    parser.add_argument('--config', action='store', default='/usr/local/etc/surgat.conf',
                        help='Configuration file to use')
    args = parser.parse_args()

    if not os.path.exists(args.config):
        print("The config file '{}' does not exist. Unable to continue.".format(args.config))
        sys.exit(0)

    config = ConfigParser.ConfigParser()
    config.read(args.config)
    cfg_data = config_dict_from_parser(config)
    cfg_data['cfg_fn'] = args.config

    pprint.pprint(cfg_data)

    sms = SurgatMailServer(cfg_data)
    sms.start()
    try:
        asyncore.loop()
    except KeyboardInterrupt:
        pass
