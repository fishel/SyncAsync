<?php

#get common constants and functions from here:
include("trcommon.php");

#error code to print in case of errors
$ERROR_CODE = "-1";

if ($_POST) {
	checkIfServersUp($_POST['langpair']);
}

if ($_GET) {
	checkIfServersUp($_GET['langpair']);
}

print "1";

?>
