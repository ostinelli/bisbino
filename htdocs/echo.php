<?php
// set header
header("content-type: text/xml");
// get request
if (isset($_GET['value'])) {
        echo "<http_test><value>".$_GET["value"]."</value></http_test>";
} else {
        echo "<http_test><error>no value specified</error></http_test>";
}
?>