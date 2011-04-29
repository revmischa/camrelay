#!/usr/bin/perl

use Moose;

# needed to handle client disconnections properly
# https://github.com/miyagawa/Twiggy/issues/7
use EV;

use Tatsumaki::Error;
use Tatsumaki::Application;
use Tatsumaki::HTTPClient;

package CamHandler;

use Moose;
use MooseX::NonMoose;
extends 'Tatsumaki::Handler';

use AnyEvent;
use AnyEvent::HTTP;
use Tatsumaki::MessageQueue;
use Encode;

__PACKAGE__->asynchronous(1);

our $receiver = AnyEvent->condvar;
our $client_id = 1;

$Tatsumaki::MessageQueue::BacklogLength = 1;

start_reading();

sub start_reading {
    my $url = "http://127.0.0.1:8888/mjpg/video.mjpg";
    my %opts = (
                on_header => \&got_headers,
                on_body  => \&got_body,
    );
    
    http_get $url, %opts, \&body_finished;
}

around 'finish' => sub {
    my ($orig, $self, @extra) = @_;

    warn "finished";
    return $self->$orig(@extra);
};

sub get {
    my($self, $query) = @_;

    $self->response->content_type('multipart/x-mixed-replace; boundary=--myboundary');
    $self->response->header(connection => 'close');

    my $mq = Tatsumaki::MessageQueue->instance('cam');
    my $_client_id = $client_id++;
    $self->{_client_id} = $_client_id;

    $mq->poll($_client_id, sub {
        my @events = @_;
        for my $event (@events) {
            my $type = $event->{type};
            my $data = $event->{data};

            if ($type eq 'mjpg-part') {
                $self->stream_write($data);
            } elsif ($type eq 'status') {
                $self->response->status($event->{status});
            } elsif ($type eq 'error') {
                Tatsumaki::Error::HTTP->throw($event->{status}, $event->{reason});
                $self->finish;
              
            } elsif ($type eq 'finish') {
                $self->finish;
            } else {
                warn "unknown event: $type";
            }
        }
    });

    return 1;
}

# this disables the default mechanism of encoding output into
# utf8. image data shouldn't be.

sub get_chunk { return $_[1] }

sub body_finished {
    my ($res, $h) = @_;

    my $mq = Tatsumaki::MessageQueue->instance('cam');

    use Data::Dumper;
    warn "finished, hdr: " . Dumper($h);

    if ($h->{Status} !~ /^2/) {
        $mq->publish({
            type => "error",
            status => $h->{Status},
            reason => $h->{Reason},
        });

        return;
    }

    $mq->publish({
        type => "finish",
    });
}

# h = hashref of headers
sub got_headers {
    my ($h) = @_;

    my $mq = Tatsumaki::MessageQueue->instance('cam');

    if ($h->{Status} !~ /^2/) {
        $mq->publish({
            type => "error",
            status => $h->{Status},
            reason => $h->{Reason},
        });

        return;
    }

    $mq->publish({
        type => "status",
        status => $h->{Status},
    });

    return 1;
}

sub got_body {
    my ($partial_body, $headers) = @_;

    my $mq = Tatsumaki::MessageQueue->instance('cam');
    $mq->publish({
        type => "mjpg-part",
        data => $partial_body,
    });

    return 1;
}

package HomeHandler;
use base qw(Tatsumaki::Handler);

sub get {
    my($self) = @_;

    $self->render('index.html');
}


package main;
use File::Basename;

my $app = Tatsumaki::Application->new([
    '/cam' => 'CamHandler',
    '/' => 'HomeHandler',
]);

$app->template_path(dirname(__FILE__) . "/templates");
$app->static_path(dirname(__FILE__) . "/static");

if (__FILE__ eq $0) {
    require Tatsumaki::Server;
    Tatsumaki::Server->new(port => 3003)->run($app);
} else {
    return $app;
}
