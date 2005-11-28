package Slim::Networking::Slimproto;

# $Id$

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use FindBin qw($Bin);
use Socket qw(inet_ntoa SOMAXCONN);
use IO::Socket;
use FileHandle;
use Sys::Hostname;
use File::Spec::Functions qw(:ALL);

use Slim::Networking::Select;
use Slim::Player::Squeezebox;
use Slim::Player::SqueezeboxG;
use Slim::Player::Squeezebox2;
use Slim::Player::SoftSqueeze;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use Errno qw(:POSIX);

my $SLIMPROTO_PORT = 3483;

my @deviceids = (undef, undef, 'squeezebox', 'softsqueeze','squeezebox2');

my $slimproto_socket;

our %ipport;		# ascii IP:PORT
our %inputbuffer;  	# inefficiently append data here until we have a full slimproto frame
our %parser_state; 	# 'LENGTH', 'OP', or 'DATA'
our %parser_framelength; # total number of bytes for data frame
our %parser_frametype;   # frame type eg "HELO", "IR  ", etc.
our %sock2client;	# reference to client for each sonnected sock
our %status;

our %callbacks;
our %callbacksRAWI;

sub setEventCallback {
	my $event	= shift;
	my $funcptr = shift;
	$callbacks{$event} = $funcptr;
}

our %message_handlers = (
	'ANIC' => \&_animation_complete_handler,
	'BODY' => \&_http_body_handler,
	'BUTN' => \&_button_handler,
	'BYE!' => \&_bye_handler,	
	'DSCO' => \&_disco_handler,
	'HELO' => \&_hello_handler,
	'IR  ' => \&_ir_handler,
	'META' => \&_http_metadata_handler,
	'RAWI' => \&_raw_ir_handler,
	'RESP' => \&_http_response_handler,
	'STAT' => \&_stat_handler,
	'UREQ' => \&_update_request_handler,
);

sub setCallbackRAWI {
	my $callbackRef = shift;
	$callbacksRAWI{$callbackRef} = $callbackRef;
}

sub clearCallbackRAWI {
	my $callbackRef = shift;
	delete $callbacksRAWI{$callbackRef};
}

sub init {
	my $listenerport = $SLIMPROTO_PORT;

	# Some combinations of Perl / OSes don't define this Macro. Yet it is
	# near constant on all machines. Define if we don't have it.
	eval { Socket::IPPROTO_TCP() };

	if ($@) {
		*Socket::IPPROTO_TCP = sub { return 6 };
	}

	$slimproto_socket = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => $main::localClientNetAddr,
		LocalPort => $listenerport,
		Listen    => SOMAXCONN,
		ReuseAddr     => 1,
		Reuse     => 1,
		Timeout   => 0.001
	) || die "Can't listen on port $listenerport for Slim protocol: $!";

	defined(Slim::Utils::Misc::blocking($slimproto_socket,0)) || die "Cannot set port nonblocking";

	Slim::Networking::Select::addRead($slimproto_socket, \&slimproto_accept);

	$::d_slimproto && msg "Squeezebox protocol listening on port $listenerport\n";	
}

sub slimproto_accept {
	my $clientsock = $slimproto_socket->accept();

	return unless $clientsock;

	defined(Slim::Utils::Misc::blocking($clientsock,0)) || die "Cannot set port nonblocking";

	# Use the Socket variables this way to silence a warning on perl 5.6
	setsockopt ($clientsock, Socket::IPPROTO_TCP(), Socket::TCP_NODELAY(), 1);

	my $peer;

	if ($clientsock->connected) {
		$peer = $clientsock->peeraddr;
	} else {
		$::d_slimproto && msg ("Slimproto accept failed; not connected.\n");
		$clientsock->close();
		return;
	}

	if (!$peer) {
		$::d_slimproto && msg ("Slimproto accept failed; couldn't get peer address.\n");
		$clientsock->close();
		return;
	}
		
	my $tmpaddr = inet_ntoa($peer);

	if (Slim::Utils::Prefs::get('filterHosts') && !(Slim::Utils::Misc::isAllowedHost($tmpaddr))) {
		$::d_slimproto && msg ("Slimproto unauthorized host, accept denied: $tmpaddr\n");
		$clientsock->close();
		return;
	}

	$ipport{$clientsock} = $tmpaddr.':'.$clientsock->peerport;
	$parser_state{$clientsock} = 'OP';
	$parser_framelength{$clientsock} = 0;
	$inputbuffer{$clientsock}='';

	Slim::Networking::Select::addRead($clientsock, \&client_readable);
	Slim::Networking::Select::addError($clientsock, \&slimproto_close);

	$::d_slimproto && msg ("Slimproto accepted connection from: $tmpaddr\n");
}

sub slimproto_close {
	my $clientsock = shift;
	$::d_slimproto && msg("Slimproto connection closed\n");

	# stop selecting
	Slim::Networking::Select::addRead($clientsock, undef);
	Slim::Networking::Select::addError($clientsock, undef);
	Slim::Networking::Select::addWrite($clientsock, undef);

	# close socket
	$clientsock->close();

	# forget state
	delete($ipport{$clientsock});
	delete($parser_state{$clientsock});
	delete($parser_framelength{$clientsock});
	delete($sock2client{$clientsock});
}		

sub client_writeable {
	my $clientsock = shift;

	# this prevent the "getpeername() on closed socket" error, which
	# is caused by trying to close the file handle after it's been closed during the
	# read pass but it's still in our writeable list. Don't try to close it twice - 
	# just ignore if it shouldn't exist.
	return unless (defined($ipport{$clientsock})); 
	
	$::d_slimproto_v && msg("Slimproto client writeable: ".$ipport{$clientsock}."\n");

	if (!($clientsock->connected)) {
		$::d_slimproto && msg("Slimproto connection closed by peer in writeable.\n");
		slimproto_close($clientsock);		
		return;
	}		
}

sub client_readable {
	my $s = shift;

	$::d_slimproto_v && msg("Slimproto client readable: ".$ipport{$s}."\n");

	my $total_bytes_read=0;

GETMORE:
	if (!($s->connected)) {
		$::d_slimproto && msg("Slimproto connection closed by peer in readable.\n");
		slimproto_close($s);		
		return;
	}			

	my $bytes_remaining;

	$::d_slimproto_v && msg(join(', ', 
		"state: ".$parser_state{$s},
		"framelen: ".$parser_framelength{$s},
		"inbuflen: ".length($inputbuffer{$s})
		)."\n");

	if ($parser_state{$s} eq 'OP') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
        assert ($bytes_remaining <= 4);
	} elsif ($parser_state{$s} eq 'LENGTH') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
		assert ($bytes_remaining <= 4);
	} else {
		assert ($parser_state{$s} eq 'DATA');
		$bytes_remaining = $parser_framelength{$s} - length($inputbuffer{$s});
	}

	my $bytes_read = 0;
	my $indata = '';
	if ($bytes_remaining) {
		$::d_slimproto_v && msg("attempting to read $bytes_remaining bytes\n");
	
		$bytes_read = $s->sysread($indata, $bytes_remaining);
	
		if (!defined($bytes_read) || ($bytes_read == 0)) {
			if ($total_bytes_read == 0) {
				$::d_slimproto && msg("Slimproto half-close from client: ".$ipport{$s}."\n");
				slimproto_close($s);
				return;
			}
	
			$::d_slimproto_v && msg("no more to read.\n");
			return;
		}
	}
	$total_bytes_read += $bytes_read;

	$inputbuffer{$s}.=$indata;
	$bytes_remaining -= $bytes_read;

	$::d_slimproto_v && msg ("Got $bytes_read bytes from client, $bytes_remaining remaining\n");

	assert ($bytes_remaining>=0);

	if ($bytes_remaining == 0) {
		if ($parser_state{$s} eq 'OP') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_frametype{$s} = $inputbuffer{$s};
			$inputbuffer{$s} = '';
			$parser_state{$s} = 'LENGTH';

			$d::protocol && msg("got op: ". $parser_frametype{$s}."\n");

		} elsif ($parser_state{$s} eq 'LENGTH') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_framelength{$s} = unpack('N', $inputbuffer{$s});
			$parser_state{$s} = 'DATA';
			$inputbuffer{$s} = '';

			if ($parser_framelength{$s} > 10000) {
				$::d_slimproto && msg ("Client gave us insane length ".$parser_framelength{$s}." for slimproto frame. Disconnecting him.\n");
				slimproto_close($s);
				return;
			}

		} else {
			assert($parser_state{$s} eq 'DATA');
			assert(length($inputbuffer{$s}) == $parser_framelength{$s});
			
			my $op = $parser_frametype{$s};
			
			my $handler_ref = $message_handlers{$op};
			
			if (defined($handler_ref)) {
				
				my $client = $sock2client{$s};
			
				if (!defined($client)) {
					if ($op eq 'HELO') {
						$handler_ref->($s, \$inputbuffer{$s});
					} else {
						msg("Client not found for slimproto msg\n");
						return;
					}
				} else {
					$handler_ref->($client, \$inputbuffer{$s});
				}		
			} else {
				$::d_slimproto && msg("Unknown slimproto op: $op\n");
			}	

			$inputbuffer{$s} = '';
			$parser_frametype{$s} = '';
			$parser_framelength{$s} = 0;
			$parser_state{$s} = 'OP';
		}
	}

	$::d_slimproto_v && msg("new state: ".$parser_state{$s}."\n");
	goto GETMORE;
}

# returns the signal strength (0 to 100), outside that range, it's not a wireless connection, so return undef
sub signalStrength {

	my $client = shift;

	if (exists($status{$client}) && ($status{$client}->{'signal_strength'} <= 100)) {
		return $status{$client}->{'signal_strength'};
	} else {
		return undef;
	}
}

sub fullness {
	my $client = shift;
	
	return $status{$client}->{'fullness'};
}

# returns how many bytes have been received by the player.  Can be reset to an arbitrary value.
sub bytesReceived {
	my $client = shift;
	return ($status{$client}->{'bytes_received'});
}

sub stop {
	my $client = shift;
	$status{$client}->{'fullness'} = 0;
	$status{$client}->{'rptr'} = 0;
	$status{$client}->{'wptr'} = 0;
	$status{$client}->{'bytes_received_H'} = 0;
	$status{$client}->{'bytes_received_L'} = 0;
	$status{$client}->{'bytes_received'} = 0;
}

sub _ir_handler {
	my $client = shift;
	my $data_ref = shift;

	# format for IR:
	# [4]   time since startup in ticks (1KHz)
	# [1]	code format
	# [1]	number of bits 
	# [4]   the IR code, up to 32 bits      
	if (length($$data_ref) != 10) {
		$::d_slimproto && msg("bad length ". length($$data_ref) . " for IR. Ignoring\n");
		return;
	}

	my ($irTime, $irCode) =unpack 'NxxH8', $$data_ref;
	Slim::Hardware::IR::enqueue($client, $irCode, $irTime);

	$::d_factorytest && msg("FACTORYTEST\tevent=ir\tmac=".$client->id."\tcode=$irCode\n");	
}

sub _raw_ir_handler {
	my $client = shift;
	my $data_ref = shift;
	$::d_slimproto && msg("Raw IR, ".(length($$data_ref)/4)."samples\n");
	
	{
		no strict 'refs';
	
		foreach my $callbackRAWI (keys %callbacksRAWI) {
			$callbackRAWI = $callbacksRAWI{$callbackRAWI};
			&$callbackRAWI( $client, $$data_ref);
		}
	}
}

sub _http_response_handler {
	my $client = shift;
	my $data_ref = shift;

	# HTTP stream headers
	$::d_slimproto && msg("Squeezebox got HTTP response:\n$$data_ref\n");
	if ($client->can('directHeaders')) {
		$client->directHeaders($$data_ref);
	}

}

sub _disco_handler {
	my $client = shift;
	my $data_ref = shift;

	$::d_slimproto && msg("Squeezebox got disconnection on the data channel why: ". unpack('C', $$data_ref) . " \n");
}

sub _http_body_handler {
	my $client = shift;
	my $data_ref = shift;

	$::d_slimproto && msg("Squeezebox got body response\n");
	if ($client->can('directBodyFrame')) {
		$client->directBodyFrame($$data_ref);
	}
}
	
sub _stat_handler {
	my $client = shift;
	my $data_ref = shift;

	#struct status_struct {
	#        u32_t event;
	#        u8_t num_crlf;          // number of consecutive cr|lf received while parsing headers
	#        u8_t mas_initialized;   // 'm' or 'p'
	#        u8_t mas_mode;          // serdes mode
	#        u32_t rptr;
	#        u32_t wptr;
	#        u64_t bytes_received;
	#		 u16_t  signal_strength;
	#        u32_t  jiffies;
	#
	
	# event types:
	# 	vfdc - vfd received
	#   i2cc - i2c command recevied
	#	STMa - AUTOSTART    
	#	STMc - CONNECT      
	#	STMe - ESTABLISH    
	#	STMf - CLOSE        
	#	STMh - ENDOFHEADERS 
	#	STMp - PAUSE        
	#	STMr - UNPAUSE           // "resume"
	#	STMt - TIMER        
	#	STMu - UNDERRUN     
	#	STMl - FULL		// triggers start of synced playback
	#	STMd - DECODE_READY	// decoder has no more data
	#	STMs - TRACK_STARTED	// a new track started playing

	my ($fullnessA, $fullnessB);
	
	(	$status{$client}->{'event_code'},
		$status{$client}->{'num_crlf'},
		$status{$client}->{'mas_initialized'},
		$status{$client}->{'mas_mode'},
		$fullnessA,
		$fullnessB,
		$status{$client}->{'bytes_received_H'},
		$status{$client}->{'bytes_received_L'},
		$status{$client}->{'signal_strength'},
		$status{$client}->{'jiffies'},
		$status{$client}->{'output_buffer_size'},
		$status{$client}->{'output_buffer_fullness'},
		$status{$client}->{'elapsed_seconds'},
	) = unpack ('a4CCCNNNNnNNNN', $$data_ref);
	
	
	$status{$client}->{'bytes_received'} = $status{$client}->{'bytes_received_H'} * 2**32 + $status{$client}->{'bytes_received_L'}; 

	if ($client->model() ne 'squeezebox2' && $client->model() ne 'softsqueeze' &&
			$client->revision() < 20 && $client->revision() > 0) {
		$client->bufferSize(262144);
		$status{$client}->{'rptr'} = $fullnessA;
		$status{$client}->{'wptr'} = $fullnessB;

		my $fullness = $status{$client}->{'wptr'} - $status{$client}->{'rptr'};
		if ($fullness < 0) {
			$fullness = $client->bufferSize() + $fullness;
		};
		$status{$client}->{'fullness'} = $fullness;
	} else {
		$client->bufferSize($fullnessA);
		$status{$client}->{'fullness'} = $fullnessB;
	}
	$client->songElapsedSeconds($status{$client}->{'elapsed_seconds'});
	if (defined($status{$client}->{'output_buffer_fullness'})) {
		$client->outputBufferFullness($status{$client}->{'output_buffer_fullness'});
	}

	$::perfmon && ($client->playmode() eq 'play') && $client->bufferFullnessLog()->log($client->usage()*100);
	$::perfmon && ($status{$client}->{'signal_strength'} <= 100) &&
		$client->signalStrengthLog()->log($status{$client}->{'signal_strength'});
		
	
	$::d_factorytest && msg("FACTORYTEST\tevent=stat\tmac=".$client->id."\tsignalstrength=$status{$client}->{'signal_strength'}\n");

# TODO make a "verbose" option for this
#		0 &&
	$::d_slimproto && msg($client->id() . " Squeezebox stream status:\n".
#		"	event_code:      $status{$client}->{'event_code'}\n".
#		"	num_crlf:        $status{$client}->{'num_crlf'}\n".
#		"	mas_initiliazed: $status{$client}->{'mas_initialized'}\n".
#		"	mas_mode:        $status{$client}->{'mas_mode'}\n".
#		"	bytes_rec_H      $status{$client}->{'bytes_received_H'}\n".
#		"	bytes_rec_L      $status{$client}->{'bytes_received_L'}\n".
	"	fullness:        $status{$client}->{'fullness'} (" . int($status{$client}->{'fullness'}/$client->bufferSize()*100) . "%)\n".
	"	bytes_received   $status{$client}->{'bytes_received'}\n".
#		"	signal_strength: $status{$client}->{'signal_strength'}\n".
#		"	jiffies:         $status{$client}->{'jiffies'}\n".
	"");
	$::d_slimproto_v && defined($status{$client}->{'output_buffer_size'}) && msg("".
	"	output size:     $status{$client}->{'output_buffer_size'}\n".
	"	output fullness: $status{$client}->{'output_buffer_fullness'}\n".
	"	elapsed seconds: $status{$client}->{'elapsed_seconds'}\n".
	"");

	Slim::Player::Sync::checkSync($client);
	
	my $callback = $callbacks{$status{$client}->{'event_code'}};

	&$callback($client) if $callback;
	
} 

	
sub _update_request_handler {
	my $client = shift;
	my $data_ref = shift;

	# THIS IS ONLY FOR SDK5.X-BASED FIRMWARE OR LATER
	$::d_slimproto && msg("Client requests firmware update");
	$client->unblock();
	$client->upgradeFirmware();		
}
	
sub _animation_complete_handler {
	my $client = shift;
	my $data_ref = shift;

	$client->endAnimation(0.5);
}

sub _http_metadata_handler {
	my $client = shift;
	my $data_ref = shift;

	$::d_directstream && msg("metadata (len: ". length($$data_ref) ."): $$data_ref\n");
	if ($client->can('directMetadata')) {
		$client->directMetadata($$data_ref);
	}
}

sub _bye_handler {
	my $client = shift;
	my $data_ref = shift;
	# THIS IS ONLY FOR THE OLD SDK4.X UPDATER

	$::d_slimproto && msg("Slimproto: Saying goodbye\n");
	if ($$data_ref eq chr(1)) {
		$::d_slimproto && msg("Going out for upgrade...\n");
		# give the player a chance to get into upgrade mode
		sleep(2);
		$client->unblock();
		$client->upgradeFirmware();
	}
	
} 

sub _hello_handler {
	my $s = shift;
	my $data_ref = shift;
	
	my ($deviceid, $revision, @mac, $bitmapped, $reconnect, $wlan_channellist, $bytes_received_H, $bytes_received_L, $bytes_received);

	(	$deviceid, $revision, 
		$mac[0], $mac[1], $mac[2], $mac[3], $mac[4], $mac[5],
		$wlan_channellist, $bytes_received_H, $bytes_received_L
	) = unpack("CCH2H2H2H2H2H2nNN", $$data_ref);

	$bitmapped = $wlan_channellist & 0x8000;
	$reconnect = $wlan_channellist & 0x4000;
	$wlan_channellist = sprintf('%04x', $wlan_channellist & 0x3fff);
	if (defined($bytes_received_H)) {
		$bytes_received = $bytes_received_H * 2**32 + $bytes_received_L; 
	}

	my $mac = join(':', @mac);
	$::d_slimproto && msg(	
		"Squeezebox says hello.\n".
		"\tDeviceid: $deviceid\n".
		"\trevision: $revision\n".
		"\tmac: $mac\n".
		"\tbitmapped: $bitmapped\n".
		"\treconnect: $reconnect\n".
		"\twlan_channellist: $wlan_channellist\n"
		);
	if (defined($bytes_received)) {
		$::d_slimproto && msg(
			"Squeezebox also says.\n".
			"\tbytes_received: $bytes_received\n"
		);
	}

	$::d_factorytest && msg("FACTORYTEST\tevent=helo\tmac=$mac\tdeviceid=$deviceid\trevision=$revision\twlan_channellist=$wlan_channellist\n");

	my $id=$mac;
	
	#sanity check on socket
	return if (!$s->peerport || !$s->peeraddr);
	
	my $paddr = sockaddr_in($s->peerport, $s->peeraddr);
	my $client = Slim::Player::Client::getClient($id); 
	
	my $client_class;
	if (!defined($deviceids[$deviceid])) {
		$::d_slimproto && msg("unknown device id $deviceid in HELO framem closing connection\n");
		slimproto_close($s);
		return;
	} elsif ($deviceids[$deviceid] eq 'squeezebox2') {
		$client_class = 'Slim::Player::Squeezebox2';
	} elsif ($deviceids[$deviceid] eq 'squeezebox') {	
		if ($bitmapped) {
				$client_class = 'Slim::Player::SqueezeboxG';
		} else {
				$client_class = 'Slim::Player::Squeezebox';
		}
	} elsif ($deviceids[$deviceid] eq 'softsqueeze') {
			$client_class = 'Slim::Player::SoftSqueeze';
	} else {
		$::d_slimproto && msg("unknown device type for $deviceid in HELO framem closing connection\n");
		slimproto_close($s);
		return;
	}			

	if (defined $client && !$client->isa($client_class)) {
		msg("forgetting client, it is not a $client_class\n");
		Slim::Player::Client::forgetClient($client);
		$client = undef;
	}

	if (!defined($client)) {
		$::d_slimproto && msg("creating new client, id:$id ipport: $ipport{$s}\n");

		$client = $client_class->new(
			$id, 		# mac
			$paddr,		# sockaddr_in
			$revision,	# rev
			$s		# tcp sock
		);

		$client->macaddress($mac);
		$client->init();
		$client->reconnect($paddr, $revision, $s, 0);  # don't "reconnect" if the player is new.
	} else {
		$::d_slimproto && msg("hello from existing client: $id on ipport: $ipport{$s}\n");
		$client->reconnect($paddr, $revision, $s, $reconnect, $bytes_received);
	}
	
	$sock2client{$s}=$client;
	
	if ($client->needsUpgrade()) {
		# ask for an update if the player will do it automatically
		$client->sendFrame('ureq');

		$client->brightness($client->maxBrightness());
		
		$client->block( {
			'line1' => string('PLAYER_NEEDS_UPGRADE_1'), 
			'line2' => string('PLAYER_NEEDS_UPGRADE_2'),
			'fonts' => { 
				'graphic-320x32' => 'light',
				'graphic-280x16' => 'small',
				'text'           => 2,
			}
		});
	} else {
		# workaround to handle multiple firmware versions causing blocking modes to stack
		while (Slim::Buttons::Common::mode($client) eq 'block') {
			$client->unblock();
		}
		# make sure volume is set, without changing temp setting
		$client->volume($client->volume(),
						defined($client->tempVolume()));
	}
	return;
}

sub _button_handler {
	my $client = shift;
	my $data_ref = shift;

	# handle hard buttons
	my ($time, $button) = unpack( 'NH8', $$data_ref);

	Slim::Hardware::IR::enqueue($client, $button, $time);

	$::d_slimproto && msg("hard button: $button time: $time\n");
} 

1;


