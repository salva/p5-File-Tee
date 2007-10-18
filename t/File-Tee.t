#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 38;

use File::Tee qw(tee);

open my $tfh, '>', 't/test_data'
    or die "unable to open test file";

open my $cfh, '>', 't/test_control'
    or die "unable to open test control file";

open my $cp4fh, '>', 't/test_copy_4';
select((select($cp4fh), $| = 1)[0]);

open my $cp5fh, '>', 't/test_copy_5';
select((select($cp5fh), $| = 1)[0]);

my @cap;

ok(my $pid = tee($tfh, '>', 't/test_copy', 't/test_copy_2',
                 { reopen => 't/test_copy_3' },
                 sub { print $cp4fh $_},
                 { process => sub { push @cap, $_ },
                   end => sub { print $cp5fh @cap } } ));

my $out = '';
my $l = '';
for (0..10) {
    $l = "hello world ($_)\n";
    $out .= $l;
    ok(print($tfh $l), "print $_ t");
    ok(print($cfh $l), "print $_ c");
}

alarm 10;
ok(close($tfh), "close tfh");
alarm 0;

sleep 1;

ok(open $tfh, '<', 't/test_data');
ok(open $cfh, '<', 't/test_control');
ok(open my $cpfh, '<', 't/test_copy');
ok(open my $cp2fh, '<', 't/test_copy_2');
ok(open my $cp3fh, '<', 't/test_copy_3');
ok(open $cp4fh, '<', 't/test_copy_4');
ok(open $cp5fh, '<', 't/test_copy_5');

{
    local $/;
    is($out, scalar(<$cfh>));
    is($out, scalar(<$tfh>));
    is($out, scalar(<$cpfh>));
    is($out, scalar(<$cp2fh>));
    is($out, scalar(<$cp3fh>));
    is($out, scalar(<$cp4fh>));
    is($out, scalar(<$cp5fh>));
}

END {
    unlink 't/test_data';
    unlink 't/test_control';
    unlink 't/test_copy';
    unlink 't/test_copy_2';
    unlink 't/test_copy_3';
    unlink 't/test_copy_4';
    unlink 't/test_copy_5';
}
