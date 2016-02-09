from spamc import SpamC, exceptions
import logging


logger = logging.getLogger('surgat.SAConnector')


def spamd_headers_for_message(data):
    rv = []
    for k in data.get('headers', []):
        if not k.startswith('X-Spam'):
            continue
        if not data.get('isspam', False) and k not in ['X-Spam-Status', 'X-Spam-Checker-Version']:
            continue
        rv.append('{}: {}'.format(k, data['headers'][k]))
    return rv


class SAConnector(object):
    def __init__(self, server='localhost', port=783, user=None):
        """ A connection to spamd for the prvided user. """
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
        return {'result': True if ck.get('isspam', False) else False,
                'basescore': ck.get('basescore'),
                'code': ck.get('code'),
                'score': ck.get('score'),
                'headers': spamd_headers_for_message(ck)}
