import getpass
import sys
import smtplib
import string
import random


def get_string(size=200):
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choice(chars) for _ in range(size))


TO = sys.argv[1] if len(sys.argv) > 1 else 'someone@some-domain.com'
FROM = sys.argv[2] if len(sys.argv) > 2 else getpass.getuser()
BODY = "To: {}\r\nFrom: {}\r\nSubject: Test Mail\r\n\r\n{}\r\n".format(TO, FROM, get_string())

server = smtplib.SMTP("localhost")
server.sendmail(FROM, [TO], BODY)
server.quit()

