import logging
import sys
from logging.handlers import SysLogHandler


SYSLOG_OPTS = {'facility': SysLogHandler.LOG_MAIL}
if sys.platform == 'darwin':
    SYSLOG_OPTS['address'] = '/var/run/syslog'
elif sys.platform == 'cygwin':
    SYSLOG_OPTS['address'] = ('127.0.0.1', 514)
else:
    SYSLOG_OPTS['address'] = '/dev/log'


LOG_LEVELS = {
    'DEBUG': logging.DEBUG,
    'INFO': logging.INFO,
    'WARN': logging.WARN,
    'CRITICAL': logging.CRITICAL
}


def get_surgat_logger(log_level='INFO'):
    _logger = logging.getLogger('surgat')
    _logger.setLevel(LOG_LEVELS.get(log_level, logging.INFO))
    handler = SysLogHandler(**SYSLOG_OPTS)
    formatter = logging.Formatter('%(name)s: %(levelname)s %(message)s')
    handler.setFormatter(formatter)
    _logger.addHandler(handler)
    return _logger
