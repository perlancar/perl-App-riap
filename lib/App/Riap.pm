package App::Riap;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use base qw(Term::Shell);
use utf8;

our %cmdspec;

sub history_filename {
    my $self = shift;
    $ENV{RIAP_HISTFILE} // "$ENV{HOME}/.riap_history";
}

sub load_history {
    my $self = shift;

    if ($self->{term}->Features->{setHistory}) {
        my $filename = $self->history_filename;
        return unless $filename;
        if (-r $filename) {
            $log->tracef("Loading history from %s ...", $filename);
            open(my $fh, '<', $filename)
                or die "Can't open history file $filename: $!\n";
            chomp(my @history = <$fh>);
            $self->{term}->SetHistory(@history);
            close $fh or die "Can't close history file $filename: $!\n";
        }
    }
}

sub save_history {
    my $self = shift;

    if ($self->{term}->Features->{getHistory}) {
        my $filename = $self->history_filename;
        return unless $filename;
        $log->tracef("Saving history to %s ...", $filename);
        open(my $fh, '>', $filename)
            or die "Can't open history file $filename for writing: $!\n";
        print $fh "$_\n" for grep { length } $self->{term}->GetHistory;
        close $fh or die "Can't close history file $filename: $!\n";
    }
}

sub new {
    require Perinci::Access;

    my ($class, %args) = @_;

    binmode(STDOUT, ":utf8");
    my $self = $class->SUPER::new();
    $self->load_history;

    $self->{_state}{pwd}           //= $args{pwd} // "/";
    $self->{_state}{output_format} //= $args{output_format} // "text";
    $self->{_pa} //= Perinci::Access->new;
    $self;
}

sub postloop {
    my $self = shift;
    print "\n";
    $self->save_history;
}

sub prompt_str {
    "riap> ";
}

sub _run_cmd {
    require Getopt::Long;
    require Perinci::Result::Format;

    my ($self, %args) = @_;

    $self->{_cmdstate} = {};

    local @ARGV = @{ $args{argv} };
    # convert opts to Getopt::Long specification
    {
        my @getopt;
        for my $ok (keys %{ $args{opts} // {} }) {
            my $ov = $args{opts}{$ok};

            my $ospec;
            if (length($ok) > 1) {
                $ospec = "--$ok";
            } else {
                $ospec = "-$ok";
            }
            if ($ov->{aliases}) {
                $ospec .= "|$_" for @{ $ov->{aliases} };
            }
            if ($ov->{arg_type}) {
                if ($ov->{arg_type} eq 'bool') {
                    $ospec .= "!";
                } else {
                    $ospec .= "=s";
                }
            }
            push @getopt, $ospec;
            push @getopt, sub {
                $self->{_cmdstate}{opts}{$ok} = $_[1];
            };
        }
        $log->tracef("Getopt::Long spec: %s", \@getopt);
        $self->{_cmdstate}{opts} = {};
        Getopt::Long::GetOptions(@getopt);
    }

    # call code
    $args{run}->($self, @ARGV);

    # display result
    if ($self->{_cmdstate}{res}) {
        print Perinci::Result::Format::format(
            $self->{_cmdstate}{res},
            $self->{_state}{output_format});
    }
}

sub _comp_cmd {
    my ($self, %args) = @_;

    #use Data::Dump; dd $args{argv};
    my @argv = @{ $args{argv} };
    my ($word, $line, $start) = @argv;

    # currently rather simplistic, only complete option name or uri path
    my @args = $self->line_parsed(substr($line, 0, $start));
    #use Data::Dump; dd [$word, $line, $start, \@args];
    ();
}

$cmdspec{list} = {
    name => 'ls',
    opts => {
        l => {
        },
    },
    run => sub {
        my $self = shift;
        my $urip = @_ ? $_[0] : $self->{_state}{pwd};
        $self->{_cmdstate}{res} = $self->{_pa}->request(
            list => $urip,
            {detail => $self->{_cmdstate}{opts}{l}},
        );
    },
};
sub smry_list { "Perform list request on package entity" }
sub run_list {
    my $self = shift;
    $self->_run_cmd(%{ $cmdspec{list} }, argv=>\@_);
}

sub comp_list {
    my $self = shift;
    $self->_comp_cmd(%{ $cmdspec{list} }, argv=>\@_);
}

sub alias_list { ("ls") }

$cmdspec{list} = {
    name => 'ls',
    opts => {
        l => {
        },
    },
    run => sub {
        my $self = shift;
        my $urip = @_ ? $_[0] : $self->{_state}{pwd};
        $self->{_cmdstate}{res} = $self->{_pa}->request(
            list => $urip,
            {detail => $self->{_cmdstate}{opts}{l}},
        );
    },
};

1;
# ABSTRACT: Implementation for Riap command-line shell

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

Use the provided L<riap> script.


=head1 DESCRIPTION

This is the backend/implementation for Riap client.


=head1 SEE ALSO

L<Perinci::Access>

=cut
