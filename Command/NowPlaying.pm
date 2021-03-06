package Command::NowPlaying;

use v5.10;
use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_nowplaying);

use Mojo::Discord;
use Mojo::WebService::LastFM;
use DBI;
use Component::Database;
use Component::YouTube;
use Mojo::JSON qw(encode_json decode_json);
use DateTime;
use Data::Dumper;

###########################################################################################
# Command Info
my $command = "NowPlaying";
my $access = 0; # Public
my $description = "Fetches Now Playing info from Last.FM and displays it in the channel";
my $pattern = '^(np|nowplaying|lastfm) ?(.*)$';
my $function = \&cmd_nowplaying;
my $usage = <<EOF;
```!nowplaying or !np or !lastfm```
    On first use the bot will ask you to use the set command (below) so it can associate your Discord ID to your Last.FM account.
    
    If the bot already knows your Last.FM account it will display your currently playing track from Last.FM

    !nowplaying, !np, and !lastfm are interchangeable.

```!lastfm set <Last.FM Username>```
    This tells the bot your Last.FM username so it can associate it to your Discord ID. 

    `Example:` !lastfm set vsTerminus

```!np <Last.FM Username>```
    The bot will look up the specified username instead of your own.

    `Example:` !nowplaying vsTerminus

```!np <\@DiscordUser>```
    If you specify a Discord username, the bot will look up that user's Last.FM account if it already has a Discord -> LastFM association stored for that user. If not, you will receive an error.

    `Example:` !nowplaying <\@231059560977137664>
EOF
############################################################################################

sub new
{
    my ($class, %params) = @_;
    my $self = {};
    bless $self, $class;
   
    # Setting up this command module requires the Discord connection 
    # and Database info to be passed in so it can utilize them.
    # It also needs the last.fm api key.
    $self->{'bot'} = $params{'bot'};
    my $bot = $self->{'bot'}; 

    $self->{'discord'}  = $bot->discord;
    $self->{'db'}       = $bot->db;
    $self->{'lastfm'}   = $bot->lastfm;
    $self->{'youtube'}  = $bot->youtube;
    $self->{'pattern'}  = $pattern;

    # Now register this command with the bot.

    $bot->add_command(
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

sub add_user
{
    my ($self, $discord_id, $discord_name, $lastfm_name) = @_;

    say localtime(time) . " Command::NowPlaying is adding a new mapping: $discord_id ($discord_name) -> $lastfm_name";

    my $db = $self->{'db'};
    
    my $sql = "INSERT INTO lastfm VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE discord_name = ?, lastfm_name = ?";
    $db->query($sql, $discord_id, $discord_name, $lastfm_name, $discord_name, $lastfm_name);
}

sub cmd_nowplaying
{
    my ($self, $channel, $author, $msg) = @_;

    my $user = $msg;
    my $pattern = $self->{'pattern'};
    $user =~ s/$pattern/$2/i;   # Strip the command out of the message, leaving just the args

    my $discord = $self->{'discord'};
    my $lastfm = $self->{'lastfm'};
    
    # First handle the set command.
    if ( $user =~ /^set (\w+)/i )
    {
        my $lastfm_name = $1;
        $lastfm_name =~ s/^\<(.*)\>$/$1/; # In case of stupidity, remove < > from the username.
        $self->add_user($author->{'id'}, $author->{'username'}, $lastfm_name);
        $discord->send_message( $channel, $author->{'username'} . ": I have updated your Last.FM username to `$lastfm_name`" );

        $self->nowplaying_by_username($channel, $author, $lastfm_name);
    }
    # Else, they are querying.
    elsif ( length $user )
    {
        # Are they querying a Discord Username or a Last.FM Username?
        if ( $user =~ /\<\@\!?(\d+)>/ )
        {
            # Discord user. $1 is the ID, $2 is the username.
            $self->nowplaying_by_id($channel, $author, $1);
        }
        else
        {
            $self->nowplaying_by_username($channel, $author, $user);
        }
    }
    else
    {
        $self->nowplaying_by_id($channel, $author, $author->{'id'});
    }
}

# The command function above is responsible for parsing the input and figuring out who to query (if anyone.)
# This sub does the actual work of finding someone's NowPlaying info and sending it to the Discord channel.
sub nowplaying_by_id
{
    my ($self, $channel, $author, $id) = @_;

    my $discord = $self->{'discord'};

    # Now, do we have a database entry for this user?
    my $db = $self->{'db'};
       
    my $sql = "SELECT lastfm_name FROM lastfm WHERE discord_id = ?";
    my $query = $db->query($sql, $id);
   
    # Yes, we have them.
    if ( my $row = $query->fetchrow_hashref )
    {
        my $lastfm_name = $row->{'lastfm_name'};

        $discord->get_user($id, sub
        {
            my $user = shift;
            $self->nowplaying_by_username($channel, $author, $row->{'lastfm_name'}, $user);
        }); # We need to pass this user object on as well so we put the right username in the discord message.

    }
    # We don't have them and they didn't specify a username. Ask for it.
    else
    {
        if ( $author->{'id'} == $id )   # Are they querying themselves?
        {
            $discord->send_message( $channel, "Sorry " . $author->{'username'} . ", I don't recognize you. Please tell me your Last.FM Username with the command: `!lastfm set <username>`." );
        }
        else # Querying someone else
        {
            $discord->send_message( $channel, "Sorry " . $author->{'username'} . ", I don't recognize that Discord user. You can try searching their Last.FM username instead if you know it." );
        }
    }
}

# Converts the JSON response from lastfm into a rich embed
sub to_embed
{
    my ($self, $username, $json, $youtube_url) = @_;
    my $bot = $self->{'bot'};

    my $embed = {
        'description' => '[' . $username . ' on Last.FM](http://last.fm/user/' . $username . ')',
        'fields' => [
            {
                'name' => $json->{'artist'} . ' - ' . $json->{'title'},
                'value' => $json->{'album'},
                'inline' => \1,
            },
        ],
        'thumbnail' => {
            'url' => $json->{'image'}[1]{'#text'},
        },
        'type' => 'rich',
        'url' => 'http://last.fm/user/' . $username,
        'color' => 0xffffff,
    };

    # If the song is currently playing there will not be a timestamp.
    # If there is nothing currently playing the first result will be historical and will have a timestamp.
    # If it's there, we should show it.
    if ( defined $json->{'date'} )
    {
        $embed->{'timestamp'} = DateTime->from_epoch(epoch => $json->{'date'}{'uts'})->iso8601().'Z';
    }
    
    # If we have access to the YouTube component this sub should receive a YouTube URL to include in the description.
    if ( defined $youtube_url )
    {
        $embed->{'description'} .= ' | [Listen on YouTube](' . $youtube_url . ')';
    }

    return $embed;
}

# This sub does NowPlaying by username.
sub nowplaying_by_username
{
    my ($self, $channel, $author, $username, $user) = @_;
    my $discord = $self->{'discord'};
    my $lastfm = $self->{'lastfm'};
    my $youtube = $self->{'youtube'};
    my $bot = $self->{'bot'};

    my $discord_name = $author->{'username'};

    # If this was a lookup on someone else's discord ID, we will be provided with an extra user object.
    # Make sure to use the correct username in the output if that is the case.
    $discord_name = $user->{'username'} if defined $user and exists $user->{'username'};

    $lastfm->nowplaying({ user => $username, callback => sub
    { 
        my $np_json = shift;

        # If we have access to the YouTube component we can also add a link to the song on YouTube.
        if ( defined $self->{'youtube'} ) #and $bot->has_webhook($channel) ) 
        {
            $youtube->search($np_json->{'artist'} . ' - ' . $np_json->{'title'}, sub
            {
                my $yt_json = shift;
                my $youtube_link = 'https://youtube.com/watch?v=' . $yt_json->{'items'}[0]{'id'}{'videoId'};
                my $embed = $self->to_embed($username, $np_json, $youtube_link);

                $self->send_message($channel, $embed);
            });
        }
        else
        {
            my $embed = $self->to_embed($username, $np_json);
            $self->send_message($channel, $embed);
        }
    }});
}

# Figure out whether to send via regular message or webhook, and then do so
sub send_message
{
    my ($self, $channel, $embed) = @_;
    
    my $bot = $self->{'bot'};
    my $discord = $self->{'discord'};

    if ( my $hook = $bot->has_webhook($channel) )
    {
        my $param = {
            'username' => 'Last.FM',
            'avatar_url' => 'http://i.imgur.com/F9FDlQ8.png', # Audioscrobbler Logo
            'content' => '',
            'embeds' => [ $embed ],
        };

        $discord->send_webhook($channel, $hook, $param);
    }
    else    # Regular message
    {
        my $message = {
            'content' => '',
            'embed' => $embed,
        };

        $discord->send_message($channel, $message);
    }

}

1;
