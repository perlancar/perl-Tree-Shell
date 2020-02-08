package Tree::Shell;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;
use Log::ger;

use parent qw(Term::Shell);

use Color::ANSI::Util qw(ansifg);
use Term::Detect::Software qw(detect_terminal_cached);
use Time::HiRes qw(time);

$ENV{COMPLETE_GETOPT_LONG_DEFAULT_ENV} = 0;
$ENV{COMPLETE_GETOPT_LONG_DEFAULT_FILE} = 0;

sub new {
    my ($class, %args) = @_;

    $class->_install_cmds;

    my $self = $class->SUPER::new();
    $self->{program_name} = $args{program_name} // 'treesh';

    $self->load_history;

    # TODO: override some settings from env, if available
    $self->load_settings;
    $self->{_settings}{output_format} //= 'text';

    $self->{_in_completion} = 0;

    # determine color support
    $self->{use_color} //=
        (defined $ENV{NO_COLOR} ? 0 : undef) //
        $ENV{COLOR} //
        (detect_terminal_cached()->{color_depth} > 1 ? 1:0);

    # beginning state
    $self->{_state}{objects} = {};
    $self->{_state}{curobj}  = undef;

    $self;
}

# override, readline workarounds. TODO: extract routine. this is shared with
# App::riap.
sub cmdloop {
    require Carp;
    require IO::Stty;
    require Signal::Safety;

    my $o = shift;
    my $rl = $o->{term};

    local $SIG{INT} = sub {
        # save history when we are interrupted
        $o->save_history;
        print STDERR "Interrupted\n";
        if ($rl->ReadLine eq 'Term::ReadLine::Gnu') {
            IO::Stty::stty(\*STDIN, 'echo');
        }
        exit 1;
    };

    local $SIG{__DIE__} = sub {
        IO::Stty::stty(\*STDIN, 'echo');
        $o->setting('debug_stack_trace') ? Carp::confess(@_) : die(@_);
    };

    local $SIG{__WARN__} = sub {
        IO::Stty::stty(\*STDIN, 'echo');
        $o->setting('debug_stack_trace') ? Carp::cluck(@_) : warn(@_);
    };

    # some workaround for Term::ReadLine
    # say "D0, rl=", $rl->ReadLine;
    my $attribs = $rl->Attribs;
    if ($rl->ReadLine eq 'Term::ReadLine::Gnu') {
        # TR::Gnu traps our INT handler
        # ref: http://www.perlmonks.org/?node_id=1003497
        $attribs->{catch_signals} = 0;
    } elsif ($rl->ReadLine eq 'Term::ReadLine::Perl') {
        # TR::Perl messes up colors
        # doesn't do anything?
        #$rl->ornaments(0);
        #$attribs->{term_set} = ["", "", "", ""];
    }

    $o->{stop} = 0;
    $o->preloop;
    while (1) {
        my $line;
        {
            no warnings 'once';
            local $Signal::Safety = 0; # limit the use of unsafe signals
            $line = $o->readline($o->prompt_str);
        }
        last unless defined($line);
        my $time1 = time();
        $o->cmd($line);
        my $time2 = time();
        if ($o->setting('debug_time_command')) {
            say sprintf("  %.3fs", ($time2-$time1));
        }
        last if $o->{stop};
    }
    $o->postloop;
}

sub mainloop { goto \&cmdloop }

sub colorize {
    my ($self, $text, $color) = @_;
    if ($self->{use_color}) {
        ansifg($color) . $text . "\e[0m";
    } else {
        $text;
    }
}

sub settings_filename {
    my $self = shift;
    "$ENV{HOME}/.".$self->{program_name}."rc";
}

sub history_filename {
    my $self = shift;
    "$ENV{HOME}/.".$self->{program_name}."_history";
}

sub known_settings {
    state $settings;
    if (!$settings) {
        $settings = {
            debug_time_command => {
                summary => 'Show how long it takes to complete a command',
                schema  => ['bool', default=>0],
            },
            debug_completion => {
                summary => 'Whether to display debugging for tab completion',
                schema  => ['bool', default=>0],
            },
            debug_stack_trace => {
                summary => 'Whether to print stack trace on die/warning',
                schema  => ['bool', default=>0],
            },
            output_format => {
                summary => 'Output format',
                schema => ['str*', default=>'text'],
            },
        };
        require Data::Sah::Normalize;
        for (keys %$settings) {
            for ($settings->{$_}{schema}) {
                $_ = Data::Sah::Normalize::normalize_schema($_);
            }
        }
    }
    $settings;
}

sub setting {
    my $self = shift;
    my $name = shift;
    die "BUG: Unknown setting '$name'" unless $self->known_settings->{$name};
    if (@_) {
        my $oldval = $self->{_settings}{$name};
        $self->{_settings}{$name} = shift;
        return $oldval;
    }
    # return default value if not set
    unless (exists $self->{_settings}{$name}) {
        return $self->known_settings->{$name}{schema}[1]{default};
    }
    return $self->{_settings}{$name};
}

sub state {
    my $self = shift;
    my $name = shift;
    #die "BUG: Unknown state '$name'" unless $self->known_state_vars->{$name};
    if (@_) {
        my $oldval = $self->{_state}{$name};
        $self->{_state}{$name} = shift;
        return $oldval;
    }
    # return default value if not set
    #unless (exists $self->{_state}{$name}) {
    #    return $self->known_state_vars->{$name}{schema}[1]{default};
    #}
    return $self->{_state}{$name};
}

sub load_settings {
    require Config::IOD::Reader;

    my $self = shift;

    my $filename = $self->settings_filename;

  LOAD_FILE:
    {
        last unless $filename;
        last unless (-e $filename);
        log_trace("Loading settings from %s ...", $filename);
        my $res = Config::IOD::Reader->new->read_file($filename);
        last unless $res->{GLOBAL};
        for (sort keys %{$res->{GLOBAL}}) {
            $self->setting($_, $res->{GLOBAL}{$_});
        }
    }
}

sub save_settings {
    die "Unimplemented";
}

sub clear_history {
    my $self = shift;

    if ($self->{term}->Features->{setHistory}) {
        $self->{term}->SetHistory();
    }
}

sub load_history {
    my $self = shift;

    if ($self->{term}->Features->{setHistory}) {
        my $filename = $self->history_filename;
        return unless $filename;
        if (-r $filename) {
            log_trace("Loading history from %s ...", $filename);
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
        unless ($filename) {
            log_warn("Skipped saving history since filename not defined");
            return;
        }
        log_trace("Saving history to %s ...", $filename);
        open(my $fh, '>', $filename)
            or die "Can't open history file $filename for writing: $!\n";
        print $fh "$_\n" for grep { length } $self->{term}->GetHistory;
        close $fh or die "Can't close history file $filename: $!\n";
    }
}

sub postloop {
    my $self = shift;
    print "\n";
    $self->save_history;
}

sub prompt_str {
    my $self = shift;

    my $curobj = $self->state('curobj');
    my $obj = $self->state('objects')->{$curobj // ''};

    join(
        "",
        $self->colorize("treesh", "ff6347"), " ", # X:tomato
        $self->colorize(($curobj // '(no curobj)'), "eeee00"), " ", # X:yellow2
        $self->colorize(($obj ? $obj->{fs}->cwd : "/"), "00e5ee"), "", # X:turquoise2
        "> ",
    );
}

my $opts = {};
my $common_opts = {
    help    => {
        getopt=>'help|h|?',
        usage => '--help (or -v, -?)',
        handler=>sub {$opts->{help}=1},
    },
    verbose => {
        getopt=>'verbose',
        handler=>sub {$opts->{verbose}=1},
    },
    json    => {
        getopt=>'json',
        handler=>sub {$opts->{fmt}='json-pretty'},
    },
};

sub _help_cmd {
    require Perinci::CmdLine::Help;

    my ($self, %args) = @_;

    my $res = Perinci::CmdLine::Help::gen_help(
        program_name => $args{name},
        meta         => $args{meta},
        common_opts  => $common_opts,
        per_arg_json => 1,
    );
    print $res->[2];
}

sub _run_cmd {
    require Perinci::Result::Format;
    require Perinci::Sub::GetArgs::Argv;
    require Perinci::Sub::ValidateArgs;

    local $Perinci::Result::Format::Enable_Cleansing = 1;

    my ($self, %args) = @_;
    my $cmd = $args{name};

    my $res;
  RUN:
    {
        $opts = {};
        $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(
            argv => $args{argv},
            meta => $args{meta},
            check_required_args => 0,
            per_arg_json => 1,
            common_opts => $common_opts,
        );
        if ($res->[0] == 501) {
            # try sending argv to the server because we can't seem to parse it
            $res = $args{code_argv}->(@{ $args{argv} });
            last RUN;
        }
        last RUN if $res->[0] != 200;

        if ($opts->{help}) {
            $self->_help_cmd(name=>$cmd, meta=>$args{meta});
            $res = [200, "OK"];
            last;
        }

        if (@{ $res->[3]{'func.missing_args'} // [] }) {
            $res = [400, "Missing required arg(s): ".
                        join(', ', @{ $res->[3]{'func.missing_args'} })];
            last;
        }

        # validate using schemas in Rinci metadata
        my $args = $res->[2];
        $res = Perinci::Sub::ValidateArgs::validate_args_using_meta(
            args => $args,
            meta => $args{meta},
        );
        unless ($res->[0] == 200) {
            last;
        }

        $res = $args{code}->(%$args, -shell => $self);
    }

    my $fmt = $opts->{fmt} //
        $res->[3]{"x.app.treesh.default_format"} //
            $self->setting('output_format');

    print Perinci::Result::Format::format($res, $fmt);
}

sub comp_ {
    require Complete::Bash;
    require Complete::Util;

    my $self = shift;
    my ($cmd, $word0, $line, $start) = @_;

    local $self->{_in_completion} = 1;

    # add commands
    my @res = ("help", "exit");
    push @res, grep {/\A\w+\z/} keys %Tree::Shell::Commands::SPEC;

    ## add directories
    #my $dirs = $Tree::Shell::Commands::complete_path->(
    #    word => "",
    #    -shell => $self,
    #);
    #push @res, @$dirs if ref $dirs eq 'ARRAY';

    my $comp = Complete::Bash::format_completion({
        path_sep => '/',
        words    => Complete::Util::complete_array_elem(
            array=>\@res, word=>$word0),
    }, {as => 'array'});
    if ($self->setting("debug_completion")) {
        say "DEBUG: Completion (1): ".join(", ", @$comp);
    }
    @$comp;
}

sub _err {
    require Perinci::Result::Format;

    my $self = shift;

    print Perinci::Result::Format::format($_[0], "text");
}

sub catch_run {
    my $self = shift;
    my ($cmd, @argv) = @_;

    $self->_err([404, "No such command"]);
    return;
}

sub catch_comp {
    require Perinci::Sub::Complete;
    require Complete::Bash;
    require Complete::Util;

    my $self = shift;
    my ($cmd, $word, $line, $start) = @_;

    local $self->{_in_completion} = 1;

    my $meta = $Tree::Shell::Commands::SPEC{$cmd};
    return () unless $meta;

    my ($words, $cword) = @{ Complete::Bash::parse_cmdline(
        $line, $start+length($word), {truncate_current_word=>1}) };
    ($words, $cword) = @{ Complete::Bash::join_wordbreak_words(
        $words, $cword) };
    shift @$words; $cword--; # strip program name
    $opts = {};
    my $res = Perinci::Sub::Complete::complete_cli_arg(
        words => $words, cword => $cword,
        meta => $meta, common_opts => $common_opts,
        extras          => {-shell => $self},
    );
    $res = _hashify_compres($res);
    @{ Complete::Bash::format_completion({
        path_sep => '/',
        esc_mode => 'default',
        words    => Complete::Util::complete_array_elem(
            array=>$res->{words}, word=>$word),
    }, {as=>'array'})};
}

sub _hashify_compres {
    ref($_[0]) eq 'HASH' ? $_[0] : {words=>$_[0]};
}

my $installed = 0;
sub _install_cmds {
    my $class = shift;

    return if $installed;

    require Tree::Shell::Commands;
    require Complete::Util;
    for my $cmd (sort keys %Tree::Shell::Commands::SPEC) {
        next unless $cmd =~ /\A\w+\z/; # only functions
        log_trace("Installing command $cmd ...");
        my $meta = $Tree::Shell::Commands::SPEC{$cmd};
        my $code = \&{"Tree::Shell::Commands::$cmd"};
        *{"smry_$cmd"} = sub { $meta->{summary} };
        *{"run_$cmd"} = sub {
            my $self = shift;
            $self->_run_cmd(name=>$cmd, meta=>$meta, argv=>\@_, code=>$code);
        };
        *{"comp_$cmd"} = sub {
            require Complete::Bash;
            require Perinci::Sub::Complete;

            my $self = shift;
            my ($word, $line, $start) = @_;
            local $self->{_in_completion} = 1;
            my ($words, $cword) = @{ Complete::Bash::parse_cmdline(
                $line, $start+length($word), {truncate_current_word=>1}) };
            ($words, $cword) = @{ Complete::Bash::join_wordbreak_words(
                $words, $cword) };
            shift @$words; $cword--; # strip program name
            $opts = {};
            my $res = Perinci::Sub::Complete::complete_cli_arg(
                words => $words, cword => $cword,
                meta => $meta, common_opts => $common_opts,
                extras => {-shell => $self},
            );
            $res = _hashify_compres($res);

            # [ux] for cd, we want the convenience of directly completing single
            # directory name without offering the choice of '--help', '-h',
            # '../' etc unless the word contains that word
            if ($cmd eq 'cd' && $words->[$cword] !~ /^[.-]/) {
                $res->{words} = [ grep { !/^[.-]/ } @{ $res->{words} } ];
            }

            my $comp = Complete::Bash::format_completion({
                path_sep => '/',
                esc_mode => 'default',
                words    => Complete::Util::complete_array_elem(
                    array=>$res->{words}, word=>$word),
            }, {as=>'array'});
            if ($self->setting('debug_completion')) {
                say "DEBUG: Completion (2): ".join(", ", @$comp);
            }
            @$comp;
        };
        if (@{ $meta->{"x.app.treeshell.aliases"} // []}) {
            # XXX not yet installed by Term::Shell?
            *{"alias_$cmd"} = sub { @{ $meta->{"x.app.treeshell.aliases"} } };
        }
        *{"help_$cmd"} = sub { $class->_help_cmd(name=>$cmd, meta=>$meta) };
    }
    $installed++;
}

1;
# ABSTRACT: Navigate and manipulate in-memory tree objects using a CLI shell

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

See L<treesh> for more details.


=head1 SEE ALSO

=cut
