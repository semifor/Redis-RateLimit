requires perl => '5.14.1';
requires 'Carp';
requires 'Digest::SHA1';
requires 'File::Share';
requires 'File::Slurp::Tiny';
requires 'JSON::MaybeXS';
requires 'Perl6::Junction';
requires 'POSIX';
requires 'Moo';
requires 'Redis';
requires 'namespace::clean';

on test => sub {
    requires 'Digest::SHA1';
    requires 'Test::Mock::Time';
    requires 'Test::Spec';
};
