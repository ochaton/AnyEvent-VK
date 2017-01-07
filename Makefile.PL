use 5.010;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'AnyEvent::VK',
    AUTHOR           => q{Vladislav Grubov <vogrubov@mail.ru>},
    VERSION_FROM     => 'lib/AnyEvent/VK.pm',
    ABSTRACT_FROM    => 'lib/AnyEvent/VK.pm',
    LICENSE          => 'artistic_2',
    PL_FILES         => {},
    MIN_PERL_VERSION => 5.010,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
        'AnyEvent::HTTP' => 0,
        'Async::Chain' => 0,
        'HTTP::Easy' => 0,
        'JSON::XS' => 0,
    },
    PREREQ_PM => {
        #'ABC'              => 1.6,
        #'Foo::Bar::Module' => 5.0401,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'AnyEvent-VK-*' },
);
