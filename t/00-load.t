#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'AnyEvent::VK' ) || print "Bail out!\n";
}

diag( "Testing AnyEvent::VK $AnyEvent::VK::VERSION, Perl $], $^X" );
