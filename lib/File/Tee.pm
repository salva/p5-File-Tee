package File::Tee;

our $VERSION = '0.02';

use strict;
use warnings;
no warnings 'uninitialized';

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(tee);

use Carp;

use Symbol qw(qualify_to_ref);
use POSIX qw(_exit);
use Fcntl qw(:flock);

sub tee (*;@) {
    @_ >= 2 or croak 'Usage: tee($fh, $target, ...)';

    my $fh = qualify_to_ref(shift, caller);

    my $last_mode;

    my @target;
    while (@_) {
        my $arg = shift @_;
        my %target;
        my %opts = ( ref $arg eq 'HASH'
                     ? %$arg
                     : ( open => $arg ) ); 

        $target{lock} = delete $opts{lock};
        $target{prefix} = delete $opts{prefix};
        $target{process} = delete $opts{process};
        $target{mode} = delete $opts{mode};
        $target{open} = delete $opts{open};
        $target{reopen} = delete $opts{reopen};
        $target{autoflush} = delete $opts{autoflush};

        %opts and croak "bad options '".join("', '", keys %opts)."'";

        if (defined $target{reopen}) {
            croak "both 'open' and 'reopen' options used for the same target"
                if defined $target{open};
            $target{open} = $target{reopen};
            $target{reopen} = 1;
        }
        elsif (!defined $target{open}) {
            croak "missing mandatory argument 'open'";
        }

        $target{autoflush} = 1 unless defined $target{autoflush};

        $target{open} = [$target{open}]
            unless ref $target{open} eq 'ARRAY';

        unless (defined $target{mode}) {
            if (ref $target{open}[0]) {
                $target{mode} = (defined $last_mode ? $last_mode : '>>&');
            }
            else {
                my ($mode, $fn) = shift(@{$target{open}}) =~ /^(\+?[<>]{1,2}(?:&=?)?|\|-?|)\s*(.*)$/;

                $mode = (defined $last_mode ? $last_mode : '>>') unless length $mode;
                $mode = '|-' if $mode eq '|';

                unshift @{$target{open}}, $fn
                    if length $fn;

                $target{mode} = $mode;
            }
        }

        $target{mode} =~ /^(?:>{1,2}&?|\|-)$/ or croak "invalid mode '$target{mode}'";

        unless (@{$target{open}} > 0) {
            if (ref $arg ne 'HASH' and @_) {
                if ($target{mode} eq '|-') {
                    @{$target{open}} = splice @_;
                }
                else {
                    my $last_mode = $target{mode};
                    @{$target{open}} = shift;
                }
            }
            else {
                croak "missing target file name";
            }
        }

        $target{open}[0] = qualify_to_ref($target{open}[0], caller)
            if $target{mode} =~ tr/&//;

        unless ($target{mode} eq '|-') {
            open my $teefh, $target{mode}, @{$target{open}}
                or return undef;
            if ($target{reopen}) {
                $target{mode} =~ s/>+/>>/;
                close $teefh
                    or return undef;
            }
            else {
                $target{teefh} = $teefh;
                if ($target{autoflush}) {
                    my $oldsel = select $teefh;
                    $| = 1;
                    select $oldsel;
                }
            }
        }

        push @target, \%target;
    }

    my $fileno = eval { fileno($fh) };

    defined $fileno
        or croak "only real file handles can be tee'ed";

    unless (defined $fileno) {
        return undef;
    }

    # flush any data buffered in $fh
    my $oldsel = select($fh);
    my @oldstate = ($|, $%, $=, $-, $~, $^, $.);
    $| = 1;
    select $oldsel;

    open my $out, ">&$fileno" or return undef;

    $oldsel = select $out;
    $| = $oldstate[0];
    select $oldsel;

    my $pid = open $fh, '|-';
    unless ($pid) {
        defined $pid
            or return undef;

        my $error = 0;

        my $oldsel = select STDERR;
        $| = 1;

        while(!$error) {
            my $line = <>;
            last unless defined $line;
            print $out $line;
            # print $fh $line;
            for my $target (@target) {
                my $cp = $line;
                $cp = join('', $target->{process}($cp)) if $target->{process};
                $cp = $target->{prefix} . $cp if length $target->{prefix};
                my $teefh = $target->{teefh};
                unless ($teefh) {
                    undef $teefh;
                    if (open $teefh, $target->{mode}, @{$target->{open}}) {
                        unless ($target->{reopen}) {
                            $target->{teefh} = $teefh;
                            if ($target->{autoflush}) {
                                my $oldsel = select $teefh;
                                $| = 1;
                                select $oldsel;
                            }
                        }
                    }
                    else {
                        $error = 1;
                        next;
                    }
                }
                flock($teefh, LOCK_EX) if $target->{lock};
                print $teefh $cp;
                flock($teefh, LOCK_UN) if $target->{lock};

                if ($target->{reopen}) {
                    close $teefh or $error = 1;
                    delete $target->{teefh};
                }
            }

        }

        for my $target (@target) {
            my $teefh = $target->{teefh};
            if ($teefh) {
                close $teefh or $error = 1;
            }
        }

        close $out or $error = 1;

        _exit($error);
    }
    # close $teefh;

    $oldsel = select($fh);
    ($|, $%, $=, $-, $~, $^, $.) = @oldstate;
    select($oldsel);

    return $pid;
}

1;
__END__

=head1 NAME

File::Tee - replicate data sent to a Perl stream

=head1 SYNOPSIS

  use File::Tee qw(tee);

  # simple usage:
  tee(STDOUT, '>', 'stdout.txt');

  print "hello world\n";
  system "ls";

  # advanced usage:
  my $pid = tee STDERR, { prefix => "err[$$]: ", reopen => 'my.log'};

  print STDERR "foo\n";
  system("cat /bad/path");


=head1 DESCRIPTION

This module is able to replicate the data written to a Perl stream
to another stream(s). It is the Perl equivalent of the shell utility
L<tee(1)>.

It is implemeted around C<fork>, creating a new process for every
tee'ed stream. That way, there are no problems handling the output
generated by external programs run with L<system|perlfunc/system>
or by XS modules that don't go through L<perlio>.

On the other hand, it will probably fail to work on Windows... that's
a feature :-)

=head2 API

The following function can be imported from this module:

=over 4

=item tee $fh, $target, ...

redirects a copy of the data written to C<$fh> to one or several files
or streams.

C<$target, ...> is a list of target streams specifications that can
be:

=over 4

=item * file names with optional mode specifications:

  tee STDOUT, '>> /tmp/out', '>> /tmp/out2';
  tee STDOUT, '>>', '/tmp/out', '/tmp/out2';

If the mode specification is a separate argument, it will affect all
the file names following and not just the nearest one.

If mode C<|-> is used as a separate argument, the rest of the
arguments are slurped as arguments for the pipe command:

   tee STDERR, '|-', 'grep', '-i', 'error';
   tee STDERR, '| grep -i error'; # equivalent

Valid modes are C<E<gt>>, C<E<gt>E<gt>>, C<E<gt>&>, C<E<gt>E<gt>&>
and C<|->. The default mode is C<E<gt>E<gt>>.

File handles can also be used as targets:

   open my $target1, '>>', '/foo/bar';
   ...
   tee STDOUT, $target1, $target2, ...;

=item * hash references describing the targets

For instance:

  tee STDOUT, { mode => '>>', open => '/tmp/foo', lock => 1};

will copy the data sent to STDOUT to C</tmp/foo>.

The attributes that can be included inside the hash are:

=over 4

=item open => $file_name

=item reopen => $file_name

sets the target file or stream. It can contain a mode
specification and also be an array. For instance:

  tee STDOUT, { open => '>> /tmp/out' };
  tee STDOUT, { reopen => ['>>', '/tmp/out2'] };
  tee STDOUT, { open => '| grep foo > /tmp/out' };

If C<reopen> is used, the file or stream is reopen for every write
operation. The mode will be forced to append after the first
write.

=item mode => $mode

Alternative way to specify the mode to open the target file or stream

=item lock => $bool

When true, an exclusive lock is obtained on the target file before
writing to it.

=item prefix => $txt

Some text to be prepended to every line sent to the target file.

For instance:

  tee STDOUT, { prefix => 'OUT: ', lock => 1, mode => '>>', open => '/tmp/out.txt' };
  tee STDERR, { prefix => 'ERR: ', lock => 1, mode => '>>', open => '/tmp/out.txt' };

=item process => sub { ... }

A callback function that can modify the data before it gets sent to
the target file.

For instance:

  sub hexdump {
    my $data = shift;
    my @out;
    while ($data =~ /(.{1,32})/smg) {
        my $line=$1;
        my @c= (( map { sprintf "%02x",$_ } unpack('C*', $line)),
                (("  ") x 32))[0..31];
        $line=~s/(.)/ my $c=$1; unpack("c",$c)>=32 ? $c : '.' /egms;
        push @out, join(" ", @c, '|', $line), "\n";
    }
    join('', @out);
  }

  tee BINFH, { process => \&hexdump, open => '/tmp/hexout'};

=item autoflush => $bool

Sets autoflush mode for the target streams. Default is on.

=back

=back

The funcion returns the PID for the newly created process.

Inside the C<tee> pipe process created, data is readed honouring the
input record separator C<$/>.

You could also want to set the tee'ed stream in autoflush mode:

  open $fh, ...;

  my $oldsel = select $fh;
  $| = 1;
  select $fh;

  tee $fh, "> /tmp/log";

=back

=head1 BUGS

This is alpha software, not very tested. Expect bugs on it.

Probably, would not work on Windows.

Send bug reports by email or via L<the CPAN RT web|https://rt.cpan.org>.

=head1 SEE ALSO

L<IO::Tee> is a similar module implemented around tied file
handles.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Salvador FandiE<ntilde>o (sfandino@yahoo.com)

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut


