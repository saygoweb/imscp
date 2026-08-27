# Notes for Debian Buster EOL

## 1. backports is archived
Change `deb.debian.org` in sources.list to `archive.debian.org`

## 2. sury-php EOL
Use:
```
cat /etc/apt/sources.list.d/php.list
deb https://mirror-bbg-5.internet1.de/sury-php-buster/ buster main
```

