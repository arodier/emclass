emclass
=======

Email classification in perl, integrated with Amavisd

This is an attempt to emails regardless the Junk status for now.
The final goal is being able to quickly classify private emails from mailing lists and other background noises.

The first added header is 'X-Email-Type', with these values:

Internal  : same or similar domain for the sender and the recipient (not implemented yet)
Private   : private email, between two companies. Should not be a mailing list or something.
List      : proper mailing list, with standard headers
Bulk      : bulk email (detected)
Unknown   : fail to classify

When the value is detected as Bulk, the reason is specified between brackets.
Exemple: Bulk (Unsubscribe Link)

