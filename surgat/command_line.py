import argparse
import os
import sys
import ConfigParser
import asyncore
import re

from __init__ import __version__
from logs import get_surgat_logger
from replay import ReplayMessage
from surgat import SurgatMailServer


def filesize(sz):
    if sz is int:
        return sz
    sz = sz.replace(',', '')
    ck = re.search("([0-9]+)([kKmM]?)", sz)
    if ck is not None:
        sz = int(ck.group(1))
        if ck.group(2).lower() == 'k':
            sz *= 1024
        elif ck.group(2).lower() == 'm':
            sz *= 1024 * 1024
        return sz
    return sz


def check_directory(cfg_fn, directory_path):
    if not os.path.isabs(directory_path):
        return os.path.join(os.path.abspath(os.path.dirname(cfg_fn)), directory_path)
    return directory_path


def config_dict_from_parser(cfg_fn):
    cfg_dict = {}
    OPTS = {
        'local': [('Listen', 'hostname', 'localhost'),
                  ('Listen', 'port', 10025, 'int')],
        'forward': [('Forward', 'hostname', 'localhost'),
                    ('Forward', 'port', 10026, 'int')],
    }

    cfg = ConfigParser.ConfigParser()
    cfg.read(cfg_fn)

    def get_opt_or_default(cfg, opt):
        if not cfg.has_section(opt[0]):
            return opt[2]
        if not cfg.has_option(opt[0], opt[1]):
            return opt[2]
        v = cfg.get(opt[0], opt[1])
        if len(opt) > 3 and opt[3] == 'int':
            return int(v)
        return v

    # Handle special cases...
    for k in OPTS:
        val = OPTS[k]
        if type(val) is list:
            cfg_dict[k] = tuple([get_opt_or_default(cfg, x) for x in val])
        else:
            cfg_dict[k] = get_opt_or_default(cfg, val)
        if cfg_dict[k] is None:
            del(cfg_dict[k])

    if not cfg.has_section('General'):
        raise Exception("A General section is required for the configuration")

    for opt in cfg.options('General'):
        v = cfg.get('General', opt)
        if v.isdigit():
            v = int(v)
        cfg_dict[opt] = v

    if cfg.has_section('Spamd'):
        cfg_dict['spamd'] = {}
        for opt in cfg.options('Spamd'):
            v = cfg.get('Spamd', opt)
            if v.isdigit():
                v = int(v)
            cfg_dict['spamd'][opt] = v

    if 'max_size' in cfg_dict:
        cfg_dict['max_size'] = filesize(cfg_dict['max_size'])
    if 'store_directory' in cfg_dict:
        cfg_dict['store_directory'] = check_directory(cfg_fn, cfg_dict['store_directory'])
    print(cfg_dict)
    return cfg_dict


def main():
    parser = argparse.ArgumentParser(description='surgat Spamassassin Proxy server')
    parser.add_argument('--verbose', action='store_true', help='Enable verbose logging')
    parser.add_argument('--filter', action='store_true', help='Enable email filtering (for development)')
    parser.add_argument('--config', action='store', default='/usr/local/etc/surgat.conf',
                        help='Configuration file to use')
    args = parser.parse_args()

    logger = get_surgat_logger('DEBUG' if args.verbose else 'INFO')

    if not os.path.exists(args.config):
        print("The config file '{}' does not exist. Unable to continue.".format(args.config))
        sys.exit(0)

    logger.info("Starting surgat version {} using configuration from {}".format(__version__, args.config))

    cfg_data = config_dict_from_parser(args.config)
    cfg_data['cfg_fn'] = args.config
    cfg_data['do_filter'] = args.filter

    sms = SurgatMailServer(cfg_data)
    sms.start()
    try:
        asyncore.loop()
    except KeyboardInterrupt:
        pass
    logger.info("shutting down")


def replay():
    parser = argparse.ArgumentParser(description='surgat replay message script')
    parser.add_argument('file', action='store', nargs='*', help='Files to process')
    args = parser.parse_args()

    for fn in args.file:
        rm = ReplayMessage(fn)
        if not rm.is_valid or not rm.process():
            continue
