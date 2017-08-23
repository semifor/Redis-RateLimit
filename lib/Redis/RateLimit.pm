package Redis::RateLimit;
# ABSTRACT: Sliding window rate limiting with Redis

use 5.14.1;
use Moo;
use Carp;
use Digest::SHA1 qw/sha1_hex/;
use File::Share qw/dist_file/;
use File::Slurper qw/read_text/;
use JSON::MaybeXS;
use List::Util qw/any max min/;
use Redis;
use Try::Tiny;
use namespace::clean;

=attr redis

Redis client. If none is provided, a default is constructed for 127.0.0.1:6379.

=cut

has redis => (
    is       => 'ro',
    lazy     => 1,
    default  => sub { Redis->new },
    handles => { map +( "redis_$_" => $_ ), qw/
        eval evalsha hget keys sadd srem
    / },
);

=attr prefix

A prefix to be included on each redis key. This prevents collisions with
multiple applications using the same Redis DB. Defaults to 'ratelimit'.

=cut

has prefix => (
    is      => 'ro',
    lazy    => 1,
    default => sub { 'ratelimit' },
);

=attr client_prefix

Set this to a true value if using a Redis client that supports transparent
prefixing. Defaults to 0.

=cut

has client_prefix => (
    is      => 'ro',
    default => sub { 0 },
);

=attr rules

An arrayref of rules, each of which is a hashref with C<interval>, C<limit>,
and optionally C<precision> values.

=cut

has rules => (
    is       => 'ro',
    required => 1,
);

around BUILDARGS => sub {
    my ( $next, $self ) = ( shift, shift );

    my $args = $self->$next(@_);
    my $rules = delete $args->{rules};
    $args->{rules} = [
        map {
            my $rule = $_;
            defined $rule->{$_} || croak "$_ undefined" for qw/interval limit/;
            [
                map 0+$_, # numify for later JSON encoding
                @{$rule}{qw/interval limit/},
                grep defined, $rule->{precision}
            ];
        } @$rules
    ];

    return $args;
};

has _script_cache => (
    is => 'lazy',
);

sub _build__script_cache {
    my $self = shift;

    # cache scripts: { name => [ hash, script ], ... }
    my %cache =(
        check_rate_limit => [ $self->_check_limit_script ],
        check_limit_incr => [ $self->_check_limit_incr_script ],
    );
    unshift @$_, sha1_hex($$_[0]) for values %cache;

    return \%cache;
}

# Note: 1 is returned for a normal rate limited action, 2 is returned for a
# blacklisted action. Must sync with return codes in lua/check_limit.lua
sub _DENIED_NUMS { (1, 2) }

sub _read_lua {
    my ( $self, $filename ) = @_;

    my $path = dist_file('Redis-RateLimit', "$filename.lua");
    read_text($path);
}

sub _check_limit_script {
    my $self = shift;

    join("\n", map(
        $self->_read_lua($_), qw/
            unpack_args
            check_whitelist_blacklist
            check_limit
        /),
        'return 0'
    );
}

sub _check_limit_incr_script {
    my $self = shift;

    join("\n", map(
        $self->_read_lua($_), qw/
            unpack_args
            check_whitelist_blacklist
            check_limit
            check_incr_limit
        /),
    );
}

sub _exec {
    my ( $self, $name, @params ) = @_;

    my ( $hash, $script ) = @{ $self->_script_cache->{$name} };
    try {
        $self->redis_evalsha($hash, @params);
    }
    catch {
        croak $_ unless /NOSCRIPT/;
        $self->redis_eval($script, @params);
    };
}

has _json_encoder => (
    is      => 'ro',
    default => sub { JSON::MaybeXS->new(utf8 => 1) },
    handles => {
        json_encode => 'encode',
    },
);

has _whitelist_key => (
    is      => 'ro',
    default => sub { shift->_prefix_key(whitelist => 1) },
);

has _blacklist_key => (
    is      => 'ro',
    default => sub { shift->_prefix_key(blacklist => 1) },
);

sub _prefix_key {
    my ( $self, $key, $force ) = @_;

    my @parts = $key;

    # Support prefixing with an optional `force` argument, but omit prefix by
    # default if the client library supports transparent prefixing.
    unshift @parts, $self->prefix if $force || !$self->client_prefix;

    # The compact handles a falsy prefix
    #_.compact(parts).join ':'
    join ':', @parts;
}

sub _script_args {
    my ( $self, $keys, $weight ) = @_;
    $weight //= 1;

    my @adjusted_keys = map $self->_prefix_key($_), grep length, @$keys;
    croak "Bad keys: @$keys" unless @adjusted_keys;

    my $rules = $self->json_encode($self->rules);
    $weight = max($weight, 1);
    return (
        0+@adjusted_keys, @adjusted_keys,
        $rules, time, $weight, $self->_whitelist_key, $self->_blacklist_key,
    );
}

=method check($key | \@keys)

Returns true if any of the keys are rate limited.

=cut

sub check {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    my $result = $self->_exec(
        check_rate_limit => $self->_script_args($keys)
    );
    return any { $result == $_ } _DENIED_NUMS;
}

=method incr($key | \@keys [, $weight ])

Returns true if any of the keys are rate limited, otherwise, it increments
counts and returns false.

=cut

sub incr {
    my ( $self, $keys, $weight ) = @_;
    $keys = [ $keys ] unless ref $keys;

    my $result = $self->_exec(
        check_limit_incr => $self->_script_args($keys, $weight)
    );
    return any { $result == $_ } _DENIED_NUMS;
}

=method keys

Returns all of the rate limiter's with prefixes removed.

=cut

sub keys {
    my $self = shift;

    my @results = $self->redis_keys($self->_prefix_key('*'));
    my $re = $self->_prefix_key('(.+)');
    map /^$re/, @results;
}

=method violated_rules($key | \@keys)

Returns a list of rate limit rules violated for any of the keys, or an empty
list.

=cut

sub violated_rules {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    my $check_key = sub {
        my $key = shift;

        my $check_rule = sub {
            my $rule = shift;
            # Note: this mirrors precision computation in `check_limit.lua`
            # on lines 7 and 8 and count key construction on line 16
            my ( $interval, $limit, $precision ) = @$rule;
            $precision = min($precision // $interval, $interval);
            my $count_key = "$interval:$precision:";

            my $count = $self->redis_hget($self->_prefix_key($key), $count_key);
            $count //= -1;
            return unless $count >= $limit;

            return { interval => $interval, limit => $limit };
        };

        map $check_rule->($_), @{ $self->rules };
    };

    return map $check_key->($_), @$keys;
}

=method limited_keys($key | \@keys)

Returns a list of limited keys.

=cut

sub limited_keys {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    grep $self->check($_), @$keys;
}

=method whitelist($key | \@keys)

Adds the keys to the whitelist so they are never rate limited.

=cut

sub whitelist {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    for ( @$keys ) {
        my $key = $self->_prefix_key($_);
        $self->redis_srem($self->_blacklist_key, $key);
        $self->redis_sadd($self->_whitelist_key, $key);
    }
}

=method unwhitelist($key | \@keys)

Removes the keys from the whitelist.

=cut

sub unwhitelist {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    for ( @$keys ) {
        my $key = $self->_prefix_key($_);
        $self->redis_srem($self->_whitelist_key, $key);
    }
}

=method blacklist($key | \@keys)

Adds the keys to the blacklist so they are always rate limited.

=cut

sub blacklist {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    for ( @$keys ) {
        my $key = $self->_prefix_key($_);
        $self->redis_srem($self->_whitelist_key, $key);
        $self->redis_sadd($self->_blacklist_key, $key);
    }
}

=method unblacklist($key | \@keys)

Removes the keys from the blacklist.

=cut

sub unblacklist {
    my $self = shift;
    my $keys = ref $_[0] ? shift : \@_;

    for ( @$keys ) {
        my $key = $self->_prefix_key($_);
        $self->redis_srem($self->_blacklist_key, $key);
    }
}

1;

__END__

=pod

=begin :buttons

=for html
<a
href="https://travis-ci.org/semifor/Redis-RateLimit"><img src="https://travis-ci.org/semifor/Redis-RateLimit.svg?branch=master"
alt="Build Status" /></a>

=end :buttons

=head1 SYNOPSIS

    use Redis;
    use Redis::RateLimit;

    my $rules = [
        { interval => 1, limit => 5 },
        { interval => 3600, limit => 1000, precision => 100 },
    ];

    my $redis_client = Redis->new;
    my $limiter = Redis::RateLimit->new(
        redis => $redis_client,
        rules => $rules,
    );

    for ( 1..10 ) {
        say 'Is rate limited? ', $limiter->incr('127.0.0.1') ? 'true' : 'false';
    };

Output:

    Is rate limited? false
    Is rate limited? false
    Is rate limited? false
    Is rate limited? false
    Is rate limited? false
    Is rate limited? true
    Is rate limited? true
    Is rate limited? true
    Is rate limited? true
    Is rate limited? true

=head1 DESCRIPTION

A Perl library for efficient rate limiting using sliding windows stored in Redis.

This is a port of L<RateLimit.js|http://ratelimit.io/> without the non-blocking
goodness.

=head2 Features

=for :list
* Uses a sliding window for a rate limit rule
* Multiple rules per instance
* Multiple instances of RateLimit side-by-side for different categories of users.
* Whitelisting/blacklisting of keys

=head2 Background

See this excellent articles on how the sliding window rate limiting with Redis
works:

=for :list
* L<Introduction to Rate Limiting with Redis Part
  1|http://www.dr-josiah.com/2014/11/introduction-to-rate-limiting-with.html>
* L<Introduction to Rate Limiting with Redis Part
  2|http://www.dr-josiah.com/2014/11/introduction-to-rate-limiting-with_26.html>

For more information on the `weight` and `precision` options, see the second
blog post above.

=head2 TODO

=for :list
* Port the middleware for Plack

=cut
