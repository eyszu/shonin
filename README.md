# Shonin

A marketplace network. Written in POSSO stack: PostgreSQL, Crystal on the
[Spectre](https://github.com/eyszu/spectre) microframework, and SolidJS.


| Lib | Used for |
|---|---|
| [Spectre](https://github.com/eyszu/spectre) | HTTP microframework (routing, middleware, static files) |
| [Mjollnir](vendor/mjollnir) | PostgreSQL driver |
| [Immagini](https://github.com/eyszu/immagini) | Image manipulation |

Features: email + password registration with an email-verification link (printed to the server console), sessions, banning and timed suspension, stores and store management, products with images, search, cart, cash-on-delivery orders, seller-to-customer chat (long-poll), admin database backup download and an images ZIP download.

## Run it
- see README.md for each folder