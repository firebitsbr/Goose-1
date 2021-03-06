package Command::Pick;

use v5.10;
use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_pick);

use Mojo::Discord;
use Bot::Goose;

###########################################################################################
# Command Info
my $command = "Pick";
my $access = 0; # Public
my $description = "Have the bot decide your fate, you wishy washy fuck.";
my $pattern = '^(pick) ?(.*)$';
my $function = \&cmd_pick;
my $usage = <<EOF;
```!pick thing one, thing two, thing three```
    Give the bot a list of things to pick from, and separate each with a comma.
    You can have the bot pick from as many things as you want.
EOF
###########################################################################################

sub new
{
    my ($class, %params) = @_;
    my $self = {};
    bless $self, $class;
     
    # Setting up this command module requires the Discord connection 
    $self->{'bot'} = $params{'bot'};
    $self->{'discord'} = $self->{'bot'}->discord;
    $self->{'pattern'} = $pattern;

    # Register our command with the bot
    $self->{'bot'}->add_command(
        'command'       => $command,
        'access'        => $access,
        'description'   => $description,
        'usage'         => $usage,
        'pattern'       => $pattern,
        'function'      => $function,
        'object'        => $self,
    );
    
    return $self;
}

sub cmd_pick
{
    my ($self, $channel, $author, $msg) = @_;

    my $args = $msg;
    my $pattern = $self->{'pattern'};
    $args =~ s/$pattern/$2/i;

    my $discord = $self->{'discord'};
    my $replyto = '<@' . $author->{'id'} . '>';

    my $quiznos = 0;

    my @picks = split (/,+/, $args);

    my $count = scalar @picks;
    my $pick = int(rand($count)+.5)+1;  #  Add .5 so the int() rounds instead of doing floor. Otherwise the final option has a very low chance of being picked.

    unshift @picks, "spacer";   # Start things at 1 instead of 0.
    $pick =~ s/^ *//;
    
    for (my $i = 1; $i <= $count; $i++)
    {
        if ( $picks[$i] =~ /^\s*quiznos\s*$/i )
        {
            # Always pick Quiznos
            $pick = $i; 
            $quiznos = 1;
        }
    }

    if ( !$quiznos and int(rand(500)) == 420 )
    {
        $pick = $count+1;
        push @picks, 'Quiznos';
    }
    

    # Send a message back to the channel
    $discord->send_message($channel, "**$pick:** $picks[$pick]");
}

1;
