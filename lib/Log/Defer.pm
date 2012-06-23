package Log::Defer;

use strict;

our $VERSION = '0.1';

use Time::HiRes;
use Carp qw/croak/;

use Guard;


my $log_levels = {
  error => 10,
  warn => 20,
  info => 30,
  debug => 40,
};

sub new {
  my ($class, $cb, %args) = @_;
  my $self = {};
  bless $self, $class;

  croak "must provide callback to Log::Defer" unless $cb && ref $cb eq 'CODE';

  my $msg = {
    logs => [],
    start => format_time(Time::HiRes::time),
  };

  $self->{msg} = $msg;

  if (exists $args{level}) {
    if ($args{level} =~ /^\d+$/) {
      $self->{log_level} = $args{level};
    } else {
      $self->{log_level} = $log_levels->{$args{level}};
      croak "bad level value (should be an error level name or a positive integer)"
        if !defined $self->{log_level};
    }
  } else {
    $self->{log_level} = 30;
  }

  $self->{guard} = guard {
    my $end_time = format_time(Time::HiRes::time());
    my $duration = format_time($end_time - $msg->{start});
    $msg->{end} = $duration;

    foreach my $name (keys %{$msg->{timers}}) {
      push @{$msg->{timers}->{$name}}, $duration
        if @{$msg->{timers}->{$name}} == 1;
    }

    $cb->($msg);
  };

  return $self;
}


sub error {
  my ($self, @logs) = @_;

  $self->_add_log(10, @logs)
    if $self->{log_level} >= 10;
}

sub warn {
  my ($self, @logs) = @_;

  $self->_add_log(20, @logs)
    if $self->{log_level} >= 20;
}

sub info {
  my ($self, @logs) = @_;

  $self->_add_log(30, @logs)
    if $self->{log_level} >= 30;
}

sub debug {
  my ($self, @logs) = @_;

  $self->_add_log(40, @logs)
    if $self->{log_level} >= 40;
}


sub timer {
  my ($self, $name) = @_;

  croak "timer $name already registered" if defined $self->{msg}->{timers}->{$name};

  my $timer_start = format_time(Time::HiRes::time() - $self->{msg}->{start});

  $self->{msg}->{timers}->{$name} = [ $timer_start, ];

  my $msg = $self->{msg};

  return guard {
    my $timer_end = format_time(Time::HiRes::time() - $msg->{start});

    push @{$msg->{timers}->{$name}}, $timer_end;
  }
}

sub data {
  my ($self) = @_;

  $self->{msg}->{data} ||= {};

  return $self->{msg}->{data};
}



#### INTERNAL ####

sub _add_log {
  my ($self, $verbosity, @logs) = @_;

  my $time = format_time(Time::HiRes::time() - $self->{msg}->{start});

  push @{$self->{msg}->{logs}}, [$time, $verbosity, @logs];
}

sub format_time {
  my $time = shift;

  $time = 0 if $time < 0;

  return 0.0 + sprintf("%.6f", $time);
}


1;




__END__


=head1 NAME

Log::Defer - Deferred logs and timers


=head1 SYNOPSIS

    use Log::Defer;

    my $logger = Log::Defer->new(\&my_logger_function);
    $logger->info("some info message");
    undef $logger; # write out log message

    sub my_logger_function {
      my $msg = shift;
      print STDERR $msg->{logs};
    }



=head1 DESCRIPTION

B<This module doesn't actually log anything!> To use this module you also need a logging library (some of them are mentioned in L<SEE ALSO>).

B<WARNING:> This module is still under development and the API and resulting messages aren't yet considered stable.

If you're not scared off yet, please read on.

What this module does is allow you to defer recording log messages until after some kind of "transaction" has completed. Typically this transaction is something like an HTTP request or a cron job. Generally log messages are easier to read if they are recorded "atomically" and not intermingled with log messages created by other requests.

The simplest use case is outlined in the L<SYNOPSIS>. You create a new Log::Defer object and pass in a coderef. This coderef will be called with a message hash reference (C<$msg>) once the Log::Defer object is destroyed, ie once all references to the object are overwritten or go out of scope.

Why not just append messages to a string and then call your logger function once the transaction is complete?

First, if a transaction has several possible paths it can take, there is no need to manually ensure that every possible path ends up calling your logging routine at the end. The log writing will be deferred until the logger object is destroyed.

Second, in an asynchronous application where multiple asynchronous tasks are kicked off concurrently, if each task keeps a reference to the logger object, the log writing will be deferred until all tasks are finished.

Finally, Log::Defer makes it easy to gather timing information about the various stages of your request. This is explained further below.




=head1 LOG MESSAGES

Log::Defer objects provide a very basic "log level" system that should be familiar. In order of decreasing verbosity, here are the possible methods:

    $logger->debug("debug message");  # 40
    $logger->info("info message");    # 30
    $logger->warn("warn message");    # 20
    $logger->error("error message");  # 10

You can set your log level to muffle messages you aren't interested in. For example, the following logger object will only record C<warn> and C<error> logs:

    my $logger = Log::Defer->new(
                               sub { ... },
                               level => 'warn',
                             );

The default log level is C<info>.

In the deferred logging callback, the log messages are recorded in the C<logs> entry of the C<$msg> hash.




=head1 DATA

Instead of log messages that are ordered and include timestamp/verbosity information, you can directly access a C<data> hash reference with the C<data> method:

    $log->data->{junkdata} = 'some data';




=head1 TIMERS

Timer objects can be created by calling the C<timer> method on the logger object. This method should be passed a description of what you are timing.

The timer starts as soon as the timer object is created and only stops once the last reference to the timer is overwritten or go out of scope.

Here is a fairly complicated example that includes concurrent timers:

    sub handle_request {
      my $request = shift;
      my $logger = Log::Defer->new(\&my_logging_function);

      my $headers = do {
        my $parse_timer = $logger->timer('parsing request');
        parse_request($request);
      };

      my $fetch_timer = $logger->timer('fetching results');
      async_fetch_results($headers, sub {

        ## stop first timer by undefing ref, then start new timer
        undef $fetch_timer; $fetch_timer = $logger->timer('fetching results stage 2');

        async_fetch_results_stage_2($headers, sub {

          $logger; ## keep reference alive
          undef $fetch_timer;
          send_response();

        });

        my $update_cache_timer = $logger->timer('update cache');

        async_update_cach(sub {

          $logger; ## keep reference alive
          undef $update_cache_timer;

        });

      });
    }




=head1 STRUCTURED LOGS

So what is the whole point of this module? It's not only designed to be convenient to use (most logging libraries are) but also to produce "structured" log messages that are easily machine parseable.

Each structured log message will be passed as a perl data-structure to the callback passed to the C<new> constructor. What you do with that is up to you.

What follows is a prettified example of a JSON-encoded log message. Normally all unnecessary white-space is removed and it is stored on a single line so that ad-hoc command-line C<grep>ing still works.

    {
       "start" : 1340353046.93565,
       "end" : 0.202386,
       "logs" : [
          [
             0.000158,
             30,
             "This is an info message (verbosity=30)"
          ],
          [
             0.201223,
             20,
             "Warning! \n\n Here is some more data:",
             {
                 "whatever" : 987
             }
          ]
       ],
       "data" : {
          "junkdata" : "some data"
       },
       "timers" : {
          "junktimer" : [
             0.000224,
             0.100655
          ],
          "junktimer2" : [
             0.000281,
             0.202386
          ]
       }
    }


C<start> is an absolute timestamp (from epoch) L<Time::HiRes> values. All other times are relative offsets from the C<start> time.



=head1 FUTURE WORK

We should be able to do some cool stuff with strucutured logs. Here's a mock-up of something we can render given structured timer data:


    parsing request          |======|
    fetching results                |==========|
    fetching results stage 2                   |==========================|
    update cache                               |==========|
                             0                 0.05073                    0.129351
                                    0.0012                 0.084622

Log messages should be versioned and the version bumped when backwards incompatible changes are made.

Sometimes I'm still getting scientific notation even after sprintf(%f)... Must be the C<0.0 +>.

Probably no need to support log level filtering at this module's level... The user can always grep the log messages manually.








=head1 SEE ALSO

As mentioned above, this module doesn't actually log messages so you still must use some other module to write your log messages. There are many libraries on CPAN that can do this and there should be at least one that fits your requirements. Some examples are: L<Sys::Syslog>, L<Log::Dispatch>, L<Log::Handler>, L<Log::Log4perl>, L<Log::Fast>, L<AnyEvent::Log>.

There are also many other libraries that can help timing/metering your requests: L<Devel::Timer>, L<Timer::Simple>, L<Benchmark::Timer>, L<Time::Stopwatch>, L<Time::SoFar>.



=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Doug Hoyte.

This module is licensed under the same terms as perl itself.

=cut
