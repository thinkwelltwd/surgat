import Queue
import smtplib
from datetime import datetime, timedelta
import logging


logger = logging.getLogger('surgat.stats')


class BeanCounter(object):
    def __init__(self, q, report_interval, remote_addr, from_addr, to_addr):
        self.queue = q
        self.report_interval = report_interval
        self.remote_addr = remote_addr
        self.from_addr = from_addr
        self.to_addr = to_addr
        self.messages = 0
        self.rules = {}
        self.report_due = datetime.today() + timedelta(minutes=report_interval)

    def start(self):
        logger.info("BeanCounter starting collection. Report interval {} minutes".format(self.report_interval))
        while True:
            try:
                msg = self.queue.get(True, 10)
                self.queue.task_done()
                self.messages += 1
                for rule in msg.get('rules', []):
                    n = self.rules.setdefault(rule, 0)
                    print(rule)
                    self.rules[rule] = n + 1

            except Queue.Empty:
                pass

            if datetime.today() > self.report_due:
                rpt = self.generate_report()
                server = smtplib.SMTP(*self.remote_addr)
                server.sendmail(self.from_addr, self.to_addr, rpt)
                server.quit()
                logger.info("rule summary report sent")
                self.report_due = datetime.today() + timedelta(minutes=self.report_interval)

    def generate_report(self):
        rpt = "To: {}\r\nFrom: {}\r\nSubject: surgat Rule Summary\r\n\r\n".format(self.to_addr, self.from_addr)
        rpt += "Rule Usage Summary\n==================\n\n"
        rpt += "Total of {} messages scanned.\n\n".format(self.messages)
        for k in sorted(self.rules):
            rpt += "  {:<40s}: {:5d}\n".format(k, self.rules[k])
        self.rules = {}
        self.messages = 0
        return rpt
