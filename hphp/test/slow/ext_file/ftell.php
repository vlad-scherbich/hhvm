<?hh


<<__EntryPoint>>
function main_ftell() {
$tempfile = tempnam(sys_get_temp_dir(), 'vmextfiletest');

$f = fopen($tempfile, 'w');
fputs($f, "testing fseek");
fclose($f);

$f = fopen($tempfile, "r");
fseek($f, -5, SEEK_END);
var_dump(ftell($f));

unlink($tempfile);
}
