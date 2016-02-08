import email
import sys
import re
import os

from surgat import SAConnector


EMAIL_ADDR = re.compile("(.*)\<(.*\@.*)\>")


def just_email(full_addr):
    ck = EMAIL_ADDR.search(full_addr)
    if ck is not None:
        return ck.group(2)
    return full_addr


class ReplayMessage(object):
    def __init__(self, fn):
        self.msg = None
        self.results = None
        if os.path.exists(fn):
            with open(fn, 'r') as fh:
                self.msg = email.message_from_file(fh)
            self.to = just_email(self.msg['to'])

    def process(self):
        if self.msg is None:
            return False

        cx = SAConnector(user=self.to)
        if not cx.check_ping():
            print("Unable to connect to spamd...exiting")
            return False
        self.results = cx.check(str(self.msg))
        return True

    @property
    def is_valid(self):
        return self.msg is not None

    @property
    def is_spam(self):
        if self.results is None:
            return False
        return self.results.get('result', False)

