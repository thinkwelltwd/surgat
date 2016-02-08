surgat
======

A transparent mail proxy that scans mail using spamassassin.

Surgat Configuration
--------------------
The main aim is to keep things simple, so all options are contained in the surgat.conf file, which by default is looked for in /usr/local/etc. Provided it's there, running the server is as simple as ./surgat.py


Postfix Configuration
---------------------

The proxy is intended to sit between incoming messages and their onward
delivery, whether to local or remote destinations.

  +--------------+       +--------------+       +--------------+
  |              |       |              |       |              |
  | incoming     | ----> | surgat       | ----> | outgoing     |
  |      mail    |       |              |       |      mail    |
  |              |       |              |       |              |
  +--------------+       +--------------+       +--------------+
    *:25                 localhost:10025        localhost:10026

By default surgat is ocnfigured to listen on port 10025 and connect to
port 10026, on localhost only.

To direct all incoming mail via surgat, the following lines should be added 
to the main.cf file for the incoming server.

    default_transport = smtp:[127.0.0.1]:10025
    default_destination_recipient_limit = 1

Updates
-------
- 8th Feb 2016

Following a change in how the mail setup I look after is configured, I decided to rewrite this in Python as it's the language I spend time with now, making the maintenance far easier. Additionally I've moved away from all the "magic" spamd perl code and now use the spamc module to process messages via spamd. This provides imporoved results that are more predictable and consistent.

