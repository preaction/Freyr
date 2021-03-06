package Bot::Freyr;
our $VERSION = '0.001';
# ABSTRACT: IRC bot with multi-network and web API

use Bot::Freyr::Base 'Class';
use Scalar::Util qw( blessed );
use Bot::Freyr::Network;
use Bot::Freyr::Message;
use Bot::Freyr::Route;

=attr nick

The default nickname for the bot

=cut

has nick => (
    is => 'ro',
    isa => Str,
);

=attr prefix

The prefix character. A shortcut to address the bot.

=cut

has prefix => (
    is => 'ro',
    isa => Str,
);

=attr server

The default server to connect to in single-network mode. A string of
C<host:port> like C<irc.freenode.net:6667>.

=cut

has server => (
    is => 'ro',
    isa => Str,
);

=attr network

The L<network|Bot::Freyr::Network> the bot is currently connected to.

=cut

has network => (
    is => 'rw',
    isa => InstanceOf['Bot::Freyr::Network'],
    lazy => 1,
    default => sub ( $self ) {
        Bot::Freyr::Network->new(
            map {; $_ => $self->$_ }
            grep { defined $self->$_ }
            qw( nick server log )
        );
    },
);

=attr channels

The channel names to connect to in single-network mode.

=cut

has channels => (
    is => 'ro',
    isa => ArrayRef[Str],
    default => sub { [] },
);

=attr plugins

The plugins to attach to this bot, keyed by route. The plugin will be
registered with the given route.

=cut

has plugins => (
    is => 'ro',
    isa => HashRef[InstanceOf['Bot::Freyr::Plugin']],
    default => sub { {} },
);

=attr log

The Mojo::Log object attached to this bot

=cut

has log => (
    is => 'ro',
    isa => InstanceOf['Mojo::Log'],
    default => sub { Mojo::Log->new },
);

=attr ioloop

The Mojo::IOLoop the bot should use.

=cut

has ioloop => (
    is => 'ro',
    isa => InstanceOf['Mojo::IOLoop'],
    default => sub { Mojo::IOLoop->singleton },
    handles => [qw( start stop )],
);

=attr _route

The L<Bot::Freyr::Route> for the entire bot.

=cut

has _route => (
    is => 'ro',
    isa => InstanceOf['Bot::Freyr::Route'],
    lazy => 1,
    default => sub ( $self ) {
        my $nick = $self->nick;
        Bot::Freyr::Route->new(
            prefix => [
                $self->prefix,
                qr{$nick[:,\s]},
            ],
        );
    },
);

=method BUILD

Initialize the network in single-network mode.

=cut

sub BUILD( $self, @ ) {
    if ( my $network = $self->network ) {
        $network->irc->on( irc_privmsg => $self->curry::weak::_route_message( $network ) );
        $network->channel( $_ ) for $self->channels->@*;
    }
    for my $route ( keys $self->plugins->%* ) {
        my $r = $self->route->under( $route );
        $self->plugins->{ $route }->register( $r );
    }
}

=method channel( NAME )

Get a L<channel|Bot::Freyr::Channel> object, joining the channel if necessary.

=cut

sub channel( $self, $name ) {
    return $self->network->channel( $name );
}

=method route( ROUTE => DEST )

Add a route to the entire bot. Routes must be unique. Only one route will be triggered
for every message.

=cut

sub route( $self, $route=undef, $dest=undef ) {
    if ( $route && $dest ) {
        return $self->_route->msg( $route, $dest );
    }
    return $self->_route;
}

=method _route_message( NETWORK, MESSAGE )

=cut

sub _route_message( $self, $network, $irc, $irc_msg ) {
    my ( $to, @words ) = $irc_msg->{params}->@*;
    my $raw_text = join " ", @words;
    my ( $from_nick ) = $irc_msg->{prefix} =~ /^([^!]+)!([^@]+)\@(.+)$/;
    my %msg = (
        bot => $self,
        network => $network,
        nick => $from_nick,
        hostmask => $irc_msg->{prefix},
        to => $to,
        text => $raw_text,
        raw => $raw_text,
    );
    if ( $to =~ /^\#/ ) {
        $msg{ channel } = $network->channel( $to );
    }
    my $msg = Bot::Freyr::Message->new( %msg );

    my $reply = eval { $self->_route->dispatch( $msg ) };

    if ( $@ ) {
        if ( blessed $@ && $@->isa( 'Bot::Freyr::Error' ) ) {
            $msg->network->irc->write( join " ", "PRIVMSG", $msg->nick, "ERROR:", $@->error );
        }
        else {
            $self->log->warn( "Got error dispatching: $@" );
        }
    }

    # Handle simple returned replies
    # Since Mojo::IRC->write() returns the Mojo::IRC object, make sure
    # we don't allow that as a response.
    if ( $reply ) {
        if ( !( blessed $reply && $reply->isa( 'Mojo::IRC' ) ) ) {
            my @to;
            if ( $msg->channel ) {
                @to = ( $msg->channel->name, $msg->nick . ":" );
            }
            else {
                @to = ( $msg->nick );
            }
            $msg->network->irc->write( join " ", "PRIVMSG", @to, $reply );
        }
    }

    return $reply;
}

1;
__END__

=head1 SYNOPSIS

    use Bot::Freyr;
    use Bot::Freyr::Plugin::Say;

    my $bot = Bot::Freyr->new(
        host => 'irc.perl.org',
        channels => [ '#freyr' ],
        nick => 'freyr',
        prefix => '!',
        plugins => {
            say => Bot::Freyr::Plugin::Say->new,
        },
    );
    $bot->start;

    # In #freyr on irc.perl.org...
    # -- Message addressed to the bot
    # > freyr, say I'm a little teapot
    # freyr> I'm a little teapot
    # -- "prefix" message
    # > !say Short and stout
    # freyr> Short and stout

=head1 DESCRIPTION

Bot::Freyr is an IRC bot designed for multiple networks and a web interface.
