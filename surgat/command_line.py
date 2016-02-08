import argparse
import os
import sys
import ConfigParser
import asyncore
import pprint

from replay import ReplayMessage
from surgat import SurgatMailServer


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


def replay():
    parser = argparse.ArgumentParser(description='surgat replay message script')
    parser.add_argument('file', action='store', nargs='*', help='Files to process')
    args = parser.parse_args()

    for fn in args.file:
        rm = ReplayMessage(fn)
        if not rm.is_valid or not rm.process():
            continue

