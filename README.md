surgat
======

Transparent Proxy to scan mail with spamassassin.


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


