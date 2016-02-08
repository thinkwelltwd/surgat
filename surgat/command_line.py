import argparse
import logging
import os
import sys
from surgat import SurgatMailServer
import ConfigParser


def main():
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
