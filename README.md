AsyncTrSrv
==========

A PHP, Perl and SQLite implementation of an asynchronous file-based translation server front-end.

Communication protocol that this package implements:
1. a file is submitted via a POST request to translate.php,
   with the parameters file (multipart form encoding, the file to translate) and langpair (string, language pair to
   translate from and to)
- the output of translate.php is an integer job ID or -1 for errors

2. job status can be checked via checkresults.php?id=123, where 123 is the job ID that translate.php returned
- the output of checkresults.php is either 0 (pending), 1 (done) or 2 (error)

3. the translated file can retrieved via getresults.php?id=123, where 123 is the job ID that translate.php returned
- NB! after the retrieval the result is deleted, so a single job output can be retrieved only once

INSTALLATION:
- place the \*.php files into the server directory
- place the translate\_file.pl script somewhere
- place the trids.sqlite somewhere invisible to the web
- create a directory for translation jobs; its permissions have to allow the server to modify it
- set the paths of translate\_file.pl, trids.sqlite and the working directory in trcommon.php
