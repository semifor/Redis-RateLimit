package Redis::Evalsha;
# ABSTRACT: A convenient wrapper for sending Lua scripts to Redis

use Moo;
use Carp;
use Digest::SHA1 qw/sha1_hex/;
use Redis;
use Try::Tiny;
use namespace::clean;

=attr redis

An instance of C<Redis>. Required.

=cut

has redis => (
    is       => 'ro',
    required => 1,
    handles  => [ qw/eval evalsha/ ],
);

has _scripts => (
    is       => 'ro',
    init_arg => 0,
    default  => sub { {} },
);

=method add($name, $lua_script)

Adds a Lua script to be called by C<exec>, later.

=cut

sub add {
    my ( $self, $name, $script ) = @_;

    $self->_scripts->{$name} = {
        body => $script,
        hash => sha1_hex($script),
    };
}

=method exec($name, \@keys, \@args)

Executes a named Lua script, previously added.

=cut

sub exec {
    my ( $self, $name, $keys, $args ) = @_;

    my $script = $self->{_scripts}{$name}
        // die "unrecognized script name: $name";

    my @params = (0+@$keys, @$keys, @$args);
    try {
        $self->evalsha($script->{hash}, @params);
    }
    catch {
        die $_ unless /NOSCRIPT/;

        $self->eval($script->{body}, @params);
    };
}

1;

__END__

=pod

=head1 SYNOPSIS

    use Redis;
    use Redis::Evalsha;

    my $redis_client = Redis->new;

    my $evalsha = Redis::Evalsha->new(redis => $redis_client);

    # Add a series of name Lua scripts
    $evalsha->add(delequal => <<'END_LUA');
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[i])
    end
    return 0
    END_LUA

    # The 'delequal' script is now available to call using `exec`. When you
    # call this, first EVALSHA is attempted, and then it falls back to EVAL.
    $evalsha->exec('delequal', ['someKey'], ['deleteMe']);

=head1 DESCRIPTION

This is a simple wrapper around Redis::eval/evalsha. Add Lua scripts, then call
them, by name, with C<exec>. First C<evalsha> is tried, and if the script
hasn't been load, yet, C<eval> is called and it will be available to C<evalsha>
on the next call.

This is a port of
L<shavaluator-js|https://github.com/andrewrk/node-redis-evalsha>.

=head1 TODO

=for :list
* move to its own distribution

=cut
