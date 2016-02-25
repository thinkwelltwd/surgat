from spamc import SpamC, exceptions
import logging


logger = logging.getLogger('surgat.SAConnector')


def spamd_headers_for_message(data):
    rv = []
    is_spam = data.get('isspam', False)
    for k in data.get('headers', []):
        if not is_spam and k not in ['X-Spam-Status', 'X-Spam-Checker-Version']:
            continue
        if not k.startswith('X-Spam') or k == 'Subject':
            continue
        rv.append('{}: {}'.format(k, data['headers'][k]))
    return rv


class SAConnector(object):
    def __init__(self, server='localhost', port=783, user=None):
        """ A connection to spamd for the prvided user. """
        logger.info("Establishing a connection to spamd...")
        self.client = SpamC(server, port, user=user)

    def check_ping(self):
        try:
            self.client.ping()
        except exceptions.SpamCError:
            return False
        return True

    def check(self, msg):
        """ Actually do the check of the message.
        :param msg: Message body to check...
        :return: {'result': True/False, 'headers': spam-headers, 'basescore': n.n, 'score': n.n}
        """
        ck = self.client.headers(msg)
        if ck['code'] != 0:
            return {'code': ck.get('code')}
        return {'result': True if ck.get('isspam', False) else False,
                'basescore': ck.get('basescore'),
                'code': ck.get('code'),
                'score': ck.get('score'),
                'headers': spamd_headers_for_message(ck)}

    def rule_list(self, msg):
        ck = self.client.symbols(msg)
        if ck.get('code') == 0:
            return ck.get('symbols')
        return []
