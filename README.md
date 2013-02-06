SyncAsync
==========

A PHP, Perl and SQLite implementation of a translation server front-end, for synchronous sentence-based and asynchronous file-based communication. Uses Moses server for translation and re-casing.

The communication protocol that this package implements is:

1. communication is done via a POST request to translate.php. The parameters of this POST request include
    - *langpair:* language pair to translate from and into (string)
    - either *sentence:* for synchronous sentence-based communication, sentence to translate (UTF8 string)
    - or *file:* for asynchronous file-based communication, file to translate (file parameter) -- requires multipart form encoding

2. the output of translate.php depends on the translation mode:
    + for synchronous requests, the output is the status code, new line character, translation output; the status code is 0 for successful jobs
      and -1 for errors; in case of errors no translation is appended
    + for asynchronous requests, the output is either an integer job ID or -1 for errors

3. for the asynchronous mode, the job status can be checked via checkresults.php?id=123, where 123 is the job ID that translate.php returned;
the output of checkresults.php is either 0 (pending), 1 (done) or 2 (error)

4. for the asynchronous mode, once the job is done, the behavior depends on the configuration:
    + if a call-back URL is defined, a call-back POST request is sent there, with parameters requestId, fileName and file
      (the latter also being the translated file, multipart form encoding)
    + if a call-back e-mail is defined, an e-mail is sent with a link for retrieving the translated file
    + the translated file can be retrieved via getresults.php?id=123, where 123 is the job ID that translate.php returned;
      NB! after the retrieval the result is deleted, so a single job output can be retrieved only once

INSTALLATION:
- place the \*.php files from the server-files directory into the server directory; alternatively,
  link to the server-files directory
- create an SQLite database and fill it with the offweb-files/db-dump.txt dump file
- create a directory for translation jobs for the asynchronous translation mode. Its permissions have to allow the server to modify it
- copy offweb-files/config.ini\_example to offweb-files/config.ini and NB! define the correct values
  for the configuration fields for your server, specifying the location of this package for the
  translate\_file.pl script, the database, etc.
- set the path to config.ini in the beginning of your server-files/trcommon.php
