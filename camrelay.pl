#!/usr/bin/perl
use strict;
use warnings;
use Tatsumaki::Error;
use Tatsumaki::Application;
use Tatsumaki::HTTPClient;
use JSON;

package CamHandler;

use base qw(Tatsumaki::Handler);
use AnyEvent;
use AnyEvent::HTTP;
use Tatsumaki::MessageQueue;

__PACKAGE__->asynchronous(1);

our $receiver = AnyEvent->condvar;
our $client_id = 1;

sub prepare {
    my ($self) = @_;

    my $url = "http://127.0.0.1:8888/mjpg/video.mjpg";
    my %opts = (
                on_header => sub { return $self->got_headers(@_); },
                on_body  => sub { return $self->got_body(@_);},
    );
    
    http_get $url, %opts, $self->async_cb(sub { $self->body_finished(@_) });
}

sub get {
    my($self, $query) = @_;

    $self->response->content_type('multipart/x-mixed-replace; boundary=--myboundary');
    $self->response->header(connection => 'close');

    my $mq = Tatsumaki::MessageQueue->instance('cam');
    $mq->poll($client_id++, sub {
        my @events = @_;
        for my $event (@events) {
            $self->stream_write($event->{data});
        }
    });

    return 1;
}

sub body_finished {
    my ($self, $res, $hdr) = @_;

    use Data::Dumper;
    warn "finished, hdr: " . Dumper($hdr);

    if ($hdr->{Status} !~ /^2/) {
        Tatsumaki::Error::HTTP->throw($hdr->{Status}, $hdr->{Reason});
    }

    $self->finish;
}

# h = hashref of headers
sub got_headers {
    my ($self, $h) = @_;

    use Data::Dumper;
    warn Dumper($h);

    if ($h->{Status} !~ /^2/) {
        Tatsumaki::Error::HTTP->throw($h->{Status}, $h->{Reason});
    }

    $self->response->status($h->{Status});

    return 1;
}

sub got_body {
    my ($self, $partial_body, $headers) = @_;

    my $mq = Tatsumaki::MessageQueue->instance('cam');
    warn "got_body";
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
