package Slim::Music::iTunes;

# SlimServer Copyright (C) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# todo:
#   Enable saving current playlist in iTunes playlist format

# LKS 05-May-2004
#
# This module supports the following configuration variables:
#
#	itunes	-- 1 to attempt to use iTunes library XML file,
#		0 to simply scan filesystem.
#
#	itunes_library_autolocate
#		-- if this is set (1), attempt to automatically set both
#		itunes_library_xml_path or itunes_library_music_path.  If
#		this is unset (0) or undefined, you MUST explicitly set both
#		itunes_library_xml_path and itunes_library_music_path.
#
#	itunes_library_xml_path
#		-- full path to 'iTunes Music Library.xml' file.
#
#	itunes_library_music_path
#		-- full path to 'iTunes Music' directory (that is, the
#		directory that contains your actual song files).
#
#	ignoredisableditunestracks
#		-- if this is set (1), songs that are 'disabled' (unchecked)
#		in iTunes will still be available to Slimserver.  If this is
#		unset (0) or undefined, disabled songs will be skipped.
#
#	itunesscaninterval
#		-- how long to wait between checking
#		'iTunes Music Library.xml' for changes.

use strict;

use Fcntl ':flock'; # import LOCK_* constants
use File::Spec::Functions qw(:ALL);
use File::Basename;
if ($] > 5.007) {
	require Encode;
}

use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

my $lastMusicLibraryFinishTime = undef;
my $isScanning = 0;
my $opened = 0;
my $locked = 0;
my $iBase = '';

my $inPlaylists;
my $inTracks;
my %tracks;
my $applicationVersion;
my $majorVersion;
my $minorVersion;

my $ituneslibrary;
my $ituneslibraryfile;
my $ituneslibrarypath;

my $initialized = 0;

# mac file types
my %filetypes = (
	1095321158 => 'aif', # AIFF
	1295270176 => 'mov', # M4A 
	1295270432 => 'mov', # M4B 
#	1295274016 => 'mov', # M4P 
	1297101600 => 'mp3', # MP3 	
	1297101601 => 'mp3', # MP3! 
	1297106247 => 'mp3', # MPEG
	1297106738 => 'mp3', # MPG2 
	1297106739 => 'mp3', # MPG3 
	1299148630 => 'mov', # MooV
	1299198752 => 'mp3', # Mp3 
	1463899717 => 'wav', # WAVE
	1836069665 => 'mp3', # mp3! 
	1836082995 => 'mp3', # mpg3 
	1836082996 => 'mov', # mpg4
);

# this library imports the iTunes Music Library.xml file for use as the music
# database, instead of scanning the file system.

# should we use the itunes library?

# LKS 05-May-2004
# I have also removed the conditional code surrounding the handling
# of $newValue, since set or not we still called canUseiTunesLibrary().
# All the extra code wasn't really gaining us anything.
sub useiTunesLibrary {
	$::d_itunes_verbose && msg("useiTunesLibrary().\n");
	
	my $newValue = shift;
	
	if (defined($newValue)) {
			Slim::Utils::Prefs::set('itunes', $newValue);
		}
	
	my $use = Slim::Utils::Prefs::get('itunes');
	
	my $can = canUseiTunesLibrary();
	
	if (!defined($use) && $can) { 
			Slim::Utils::Prefs::set('itunes', 1);
	} elsif (!defined($use) && !$can) {
			Slim::Utils::Prefs::set('itunes', 0);
	}
	
	$use = Slim::Utils::Prefs::get('itunes');
	Slim::Music::Import::useImporter('itunes',$use && $can);
	
	$::d_itunes && msg("using itunes library: $use\n");
	
	return $use && $can;
}

sub canUseiTunesLibrary {
	$::d_itunes && msg("canUseiTunesLibrary().\n");
	checkDefaults() unless $initialized;
	Slim::Web::Setup::addChildren('server','itunes',3);
	$ituneslibraryfile = defined $ituneslibraryfile ? $ituneslibraryfile : findMusicLibraryFile();
	$ituneslibrarypath = defined $ituneslibrarypath ? $ituneslibrarypath : findMusicLibrary();
	if (defined $ituneslibraryfile && $ituneslibrarypath) {
		init();
	}
	return defined $ituneslibraryfile && $ituneslibrarypath;
}

sub init {
	return if $initialized;
	#Slim::Utils::Strings::addStrings($strings);
	Slim::Music::Import::addImporter('itunes',\&startScan);
	Slim::Player::Source::registerProtocolHandler("itunesplaylist", "0");
	Slim::Web::Setup::addCategory('itunes',&setupCategory);
	my ($groupRef,$prefRef) = &setupGroup();
	Slim::Web::Setup::addGroup('server','itunes',$groupRef,1,$prefRef);
	
	$initialized = 1;
}

sub findLibraryFromPlist {
	$::d_itunes && msg("findLibraryFromPlist().\n");

	my $path = undef;
	my $base = shift @_;
	my $plist = catfile(($base, 'Library', 'Preferences'),
		'com.apple.iApps.plist');

	if (-r $plist) {
		open (PLIST, "< $plist");
		while (<PLIST>) {
			if ( /<string>(.*iTunes%20Music%20Library.xml)<\/string>$/) {
				$path = Slim::Utils::Misc::pathFromFileURL($1);
				last;
			}
		}
	}

	return $path;
}
	
sub findLibraryFromRegistry {
	$::d_itunes && msg("findLibraryFromRegistry().\n");

	my $path = undef;

	if (Slim::Utils::OSDetect::OS() eq 'win') {
		if (!eval "use Win32::Registry;") {
			my $folder;
			if ($::HKEY_CURRENT_USER->Open("Software\\Microsoft\\Windows"
					."\\CurrentVersion\\Explorer\\Shell Folders",
					$folder)) {
				my ($type, $value);
				if ($folder->QueryValueEx("My Music", $type, $value)) {
					$path = $value . '\\iTunes\\iTunes Music Library.xml';
					$::d_itunes && msg("iTunes: found My Music here: $value for $path\n");
				}
				if ($path && -r $path) {
					return $path;
				} elsif ($folder->QueryValueEx("Personal", $type, $value)) {
						$path = $value . '\\My Music\\iTunes\\iTunes Music Library.xml';
						$::d_itunes && msg("iTunes: found  Personal: $value for $path\n");
				}
			}
		}
	}
	
	return $path;
}

sub findMusicLibraryFile {
	$::d_itunes && msg("findMusicLibraryFile().\n");

	my $path = undef;

	my $base = "";
	$base = $ENV{HOME} if $ENV{HOME};

	my $audiodir = Slim::Utils::Prefs::get('audiodir');
	my $autolocate = Slim::Utils::Prefs::get('itunes_library_autolocate');

	if ($autolocate) {
		$::d_itunes && msg("itunes: attempting to locate iTunes Music Library.xml\n");
	
		# This defines the list of directories we will search for
		# the 'iTunes Music Library.xml' file.
		my @searchdirs = (
			catdir($base, 'Music', 'iTunes'),
			catdir($base, 'Documents', 'iTunes'),
			$base,
		);
			
		if (defined $audiodir) {
			push @searchdirs, (
				catdir($audiodir, 'My Music', 'iTunes'),
				catdir($audiodir, 'iTunes'),
				$audiodir
			);
		}

		$path = findLibraryFromPlist($base);
		if ($path && -r $path) {
			$::d_itunes && msg("itunes: found path via iTunes preferences at: $path\n");
			return $path;
		}

		$path = findLibraryFromRegistry();
		if ($path && -r $path) {
			$::d_itunes && msg("itunes: found path via Windows registry at: $path\n");
			return $path;
	}		
	
		for my $dir (@searchdirs) {
			$path = catfile(($dir), 'iTunes Music Library.xml');
			if ($path && -r $path) {
				$::d_itunes && msg("itunes: found path via directory search at: $path\n");
				Slim::Utils::Prefs::set('itunes_library_xml_path',$path);
				return $path;
			}
		}
	}

	if (! $path) {
		$path = Slim::Utils::Prefs::get('itunes_library_xml_path');
		if ($path && -d $path) {
			$path = catfile(($path), 'iTunes Music Library.xml');
		}
		if ($path && -r $path) {
			Slim::Utils::Prefs::set('itunes_library_xml_path',$path);
			$::d_itunes && msg("itunes: found path via config file at: $path\n");
			return $path;
		}
	}		
	
	$::d_itunes && msg("itunes: unable to find iTunes Music Library.xml.\n");
	
	return undef;
}


sub findMusicLibrary {
	$::d_itunes_verbose && msg("findMusicLibrary().\n");
 	
	my $autolocate = Slim::Utils::Prefs::get('itunes_library_autolocate');
	my $path = undef;
	my $file = $ituneslibraryfile || findMusicLibraryFile();

	if (defined($file) && $autolocate) {
		$::d_itunes && msg("itunes: attempting to locate iTunes library relative to $file.\n");

		my $itunesdir = dirname($file);
		$path = catdir($itunesdir, 'iTunes Music');

		if ($path && -d $path) {
			$::d_itunes && msg("itunes: set iTunes library relative to $file: $path\n");
			Slim::Utils::Prefs::set('itunes_library_music_path',$path);
			return $path;
		}
	}

	$path = Slim::Utils::Prefs::get('itunes_library_music_path');
	if ($path && -d $path) {
		$::d_itunes && msg("itunes: set iTunes library to itunes_library_music_path value of: $path\n");
		return $path;
	}

	$path = Slim::Utils::Prefs::get('audiodir');
	return undef unless $path;
	$::d_itunes && msg("itunes: set iTunes library to audiodir value of: $path\n");
	Slim::Utils::Prefs::set('itunes_library_music_path',$path);
	return $path;
}

sub playlists {
	return \@Slim::Music::Info::playlists;
}

sub isMusicLibraryFileChanged {
	$::d_itunes_verbose && msg("isMusicLibraryFileChanged().\n");

	my $file = $ituneslibraryfile || findMusicLibraryFile();
	my $fileMTime = (stat $file)[9];
	
	# Only say "yes" if it has been more than one minute since we last finished scanning
	# and the file mod time has changed since we last scanned. Note that if we are
	# just starting, lastITunesMusicLibraryDate is undef, so both $fileMTime
	# will be greater than 0 and time()-0 will be greater than 180 :-)
	if ($file && $fileMTime > Slim::Utils::Prefs::get('lastITunesMusicLibraryDate')) {

		my $itunesscaninterval = Slim::Utils::Prefs::get('itunesscaninterval');

		$::d_itunes && msg("music library has changed!\n");
		return 1 if (!$lastMusicLibraryFinishTime);
		
		if (time()-$lastMusicLibraryFinishTime > $itunesscaninterval) {
			return 1;
		} else {
			$::d_itunes && msg("waiting for $itunesscaninterval seconds to pass before rescanning\n");
		}
	}
	
	return 0;
}

sub checker {
	$::d_itunes_verbose && msg("checker().\n");

	return unless (useiTunesLibrary());
	
	if (!stillScanning() && isMusicLibraryFileChanged()) {
		startScan();
	}

	# make sure we aren't doing this more than once...
	Slim::Utils::Timers::killTimers(0, \&checker);

	# Call ourselves again after 5 seconds
	Slim::Utils::Timers::setTimer(0, (Time::HiRes::time() + 5.0), \&checker);
}

sub startScan {
	$::d_itunes_verbose && msg("startScan().\n");
	if (!useiTunesLibrary()) {
		return;
	}
		
	my $file = $ituneslibraryfile || findMusicLibraryFile();
	Slim::Music::Info::clearPlaylists();
	$::d_itunes && msg("startScan: iTunes file: $file\n");

	if (!defined($file)) {
		warn "Trying to scan an iTunes file that doesn't exist.";
		return;
	}
	
	stopScan();

	$isScanning = 1;

	# start the checker
	checker();
	
	Slim::Utils::Scheduler::add_task(\&scanFunction);
} 

sub stopScan {
	$::d_itunes_verbose && msg("stopScan().\n");
	if (stillScanning()) {
		Slim::Utils::Scheduler::remove_task(\&scanFunction);
		doneScanning();
	}
}

sub stillScanning {
	return $isScanning;
}

sub doneScanning {
	$::d_itunes && msg("iTunes: done Scanning: unlocking and closing\n");

	$locked = 0;

	$opened = 0;
	
	$ituneslibrary = undef;
	
	$lastMusicLibraryFinishTime = time();

	$isScanning = 0;
	
	Slim::Music::Info::generatePlaylists();
	
	Slim::Music::Import::endImporter('itunes');
}

###########################################################################################
	# This incredibly ugly parser is highly dependent on the iTunes 3.0 file format.
	# A wise man with more time would use a true XML parser and integrate the appropriate
	# libraries into the distribution to work cross platform, until then...

    # Abandon all hope ye who enter here...
###########################################################################################
sub scanFunction {
	$::d_itunes_verbose && msg("scanFunction()\n");

	my $file = $ituneslibraryfile || findMusicLibraryFile();;
	
	# this assumes that iTunes uses file locking when writing the xml file out.
	if (!$opened) {
		if (!open(ITUNESLIBRARY, "<$file")) {
			$::d_itunes && warn "Couldn't open iTunes Library: $file";
			return 0;	
		}
		$opened = 1;
		resetScanState();
		Slim::Utils::Prefs::set('lastITunesMusicLibraryDate', (stat $file)[9]);
	}
	
	if ($opened && !$locked) {
		$locked = 1;
		$locked = flock(ITUNESLIBRARY, LOCK_SH | LOCK_NB) unless ($^O eq 'MSWin32'); 
		if ($locked) {
			$::d_itunes && msg("Got file lock on iTunes Library\n");
			$locked = 1;
			my $len = read ITUNESLIBRARY, $ituneslibrary, -s $file;
			die "couldn't read itunes library!" if (!defined($len));
			flock(ITUNESLIBRARY, LOCK_UN) unless ($^O eq 'MSWin32');
			close ITUNESLIBRARY;
			$ituneslibrary =~ s/></>\n</g;
		} else {
			$::d_itunes && warn "Waiting on lock for iTunes Library";
			return 1;
		}
	}
	
	my $curLine = getLine();
	if (!defined($curLine)) {
		$::d_itunes && msg("iTunes:  Finished scanning iTunes XML\n");
		# done scanning
		doneScanning();
		return 0;
	}
	
	if ($inTracks) {
		if ($curLine eq '</dict>') {
			$inTracks = 0;
		} elsif ($curLine =~ /<key>([^<]*)<\/key>/) {
			my $id = $1;
			my %curTrack = getDict();
			my %cacheEntry = ();
			# add this track to the library
			if ($id ne $curTrack{'Track ID'}) {
				warn "Danger, the Track ID (" . $curTrack{'Track ID'} . ") and the key ($id) don't match.\n";
			}
			
			# skip track if Disabled in iTunes
			return 1 if $curTrack{'Disabled'} && Slim::Utils::Prefs::get('ignoredisableditunestracks');

			my $kind = $curTrack{'Kind'};
			my $location = $curTrack{'Location'};
			my $filetype = $curTrack{'File Type'};
			my $type = undef;
			if ($filetype) {
				if (exists $Slim::Music::Info::types{$filetype}) {
					$type = $Slim::Music::Info::types{$filetype};
				} else {
					$type = $filetypes{$filetype};
				}
			}
			
			$::d_itunes && msg("got a track named " . $curTrack{'Name'} . " location: $location\n");

			if ($location =~ /^((\d+\.\d+\.\d+\.\d+)|([-\w]+(\.[-\w]+)*)):\d+$/) {
				$location = "http://$location"; # fix missing prefix in old invalid entries
			}

			my $url = normalize_location($location);

			if (Slim::Music::Info::isFileURL($url)) {
				my $file = Slim::Utils::Misc::pathFromFileURL($url, 1);
				
				if (!$file || !-r $file) { 
					$::d_itunes && msg("iTunes: file not found: $file\n");
					$url = undef;
				} 
			}
			
			if ($url && !defined($type)) {
				$type = Slim::Music::Info::typeFromPath($url, 'mp3');
			}

			if ($url && (Slim::Music::Info::isSong($url, $type) || Slim::Music::Info::isHTTPURL($url))) {
				# Force a reading of the file itself,
				# since lazy reading can result in slow
				# performance down the road.
				Slim::Music::Info::info($url, 'TAG');

				$cacheEntry{'CT'} = $type;
				$cacheEntry{'TITLE'} = $curTrack{'Name'};
				$cacheEntry{'ARTIST'} = $curTrack{'Artist'};
				$cacheEntry{'COMPOSER'} = $curTrack{'Composer'};
				$cacheEntry{'TRACKNUM'} = $curTrack{'Track Number'};

				my $discNum = $curTrack{'Disc Number'};
				my $discCount = $curTrack{'Disc Count'};
				$cacheEntry{'DISC'} = $discNum if defined $discNum;
				$cacheEntry{'DISCC'} = $discCount if defined $discCount;
				$cacheEntry{'ALBUM'} = $curTrack{'Album'};			

				Slim::Music::Info::addDiscNumberToAlbumTitle(\%cacheEntry);
				
				$cacheEntry{'GENRE'} = $curTrack{'Genre'};
				$cacheEntry{'FS'} = $curTrack{'Size'};
				if ($curTrack{'Total Time'}) { $cacheEntry{'SECS'} = $curTrack{'Total Time'} / 1000; };
				$cacheEntry{'BITRATE'} = $curTrack{'Bit Rate'} * 1000 if ($curTrack{'Bit Rate'});
				$cacheEntry{'YEAR'} = $curTrack{'Year'};
				$cacheEntry{'COMMENT'} = $curTrack{'Comments'};
				# cacheEntry{'???'} = $curTrack{'Track Count'};
				# cacheEntry{'???'} = $curTrack{'Sample Rate'};
				$cacheEntry{'VALID'} = '1';

				if (Slim::Utils::Prefs::get('lookForArtwork')) {
					if ($cacheEntry{'ALBUM'} && !Slim::Music::Import::artwork($cacheEntry{'ALBUM'}) && !defined Slim::Music::Info::cacheItem($url,'THUMB')) {
						Slim::Music::Import::artwork($cacheEntry{'ALBUM'},$url);
					}
				}
				Slim::Music::Info::updateCacheEntry($url, \%cacheEntry);
				$tracks{$id} = $url;
			} else {
				$::d_itunes && warn "iTunes: unknown file type " . $curTrack{'Kind'} . " $url";
			} 

		}
	} elsif ($inPlaylists) {
		if ($curLine eq '</array>') {
			$inPlaylists = 0;
		} else {
			my %curPlaylist = getDict();
			my %cacheEntry = ();
			my $name = $curPlaylist{'Name'};
			my $url = 'itunesplaylist:' . Slim::Web::HTTP::escape($name);
			$::d_itunes && msg("got a playlist ($url) named $name\n");
			# add this playlist to our playlist library
#	'LIST',	 # list items (array)
#	'AGE',   # list age
			$cacheEntry{'TITLE'} = Slim::Utils::Prefs::get('iTunesplaylistprefix') . $name . Slim::Utils::Prefs::get('iTunesplaylistsuffix');
			$cacheEntry{'LIST'} = $curPlaylist{'Playlist Items'};
			$cacheEntry{'CT'} = 'itu';
			$cacheEntry{'TAG'} = 1;
			$cacheEntry{'VALID'} = '1';
			Slim::Music::Info::updateCacheEntry($url, \%cacheEntry);
			$::d_itunes && msg("playlists now has " . scalar @{Slim::Music::Info::playlists()} . " items...\n");
		}
	} else {
		if ($curLine eq "<key>Major Version</key>") {
			$majorVersion = getValue();
			$::d_itunes && msg("iTunes Major Version: $majorVersion\n");
		} elsif ($curLine eq "<key>Minor Version</key>") {
			$minorVersion = getValue();
			$::d_itunes && msg("iTunes Minor Version: $minorVersion\n");
		} elsif ($curLine eq "<key>Application Version</key>") {
			$applicationVersion = getValue();
			$::d_itunes && msg("iTunes application version: $applicationVersion\n");
		} elsif ($curLine eq "<key>Music Folder</key>") {
			$iBase = getValue();
			#$iBase = Slim::Utils::Misc::pathFromFileURL($iBase);
			$iBase = strip_automounter($iBase);
			$::d_itunes && msg("iTunes: found the music folder: $iBase\n");
		} elsif ($curLine eq "<key>Tracks</key>") {
			$inTracks = 1;
			$inPlaylists = 0;
			$::d_itunes && msg("iTunes: starting track parsing\n");
		} elsif ($curLine eq "<key>Playlists</key>") {
			$inPlaylists = 1;
			$inTracks = 0;
			# todo, clear out the old moodlogic playlists from the info database.
			$::d_itunes && msg("iTunes: starting playlist parsing\n");
		}
	}

	return 1;
}

sub normalize_location {
	my $location = shift;
	my $url;
	
	my $stripped = strip_automounter($location);

	# on non-mac or windows, we need to substitute the itunes library path for the one in the iTunes xml file
	if (Slim::Utils::OSDetect::OS() eq 'unix') {
		# find the new base location.  make sure it ends with a slash.
		my $path = $ituneslibrarypath || findMusicLibrary();
		my $base = Slim::Utils::Misc::fileURLFromPath($path);

		$url = $stripped;		
		$url =~ s,$iBase,$base,isg;
		$url =~ s,(\w)\/\/(\w),$1\/$2,isg;
	} else {
		$url = Slim::Utils::Misc::fixPath($stripped);
	}

	$url =~ s/file:\/\/localhost\//file:\/\/\//;
	
	$::d_itunes && msg("iTunes: normalized $location to $url\n");

	return $url;
}
			

sub getValue {
	my $curLine = getLine();
	my $data = '';
	if ($curLine =~ /^<(?=[ids])(?:integer|date|string)>([^<]*)<\/(?=[ids])(?:integer|date|string)>$/) {
               $data = $1;
	} elsif ($curLine eq '<true/>') {
		$data = 1;
	} elsif ($curLine eq '<data>') {
		$curLine = getLine();
		while (defined($curLine) && ($curLine ne '</data>')) {
			$data .= $curLine;
			$curLine = getLine();
		}
	} elsif ($curLine =~ /<string>([^<]*)/) {
			$data = $1;
			$curLine = getLine();
			while (defined($curLine) && ($curLine !~ /<\/string>/)) {
				$data .= $curLine;
				$curLine = getLine();
			}
			if ($curLine =~ /([^<]*)<\/string>/) {
				$data .= $1;
			}
	}
	$data =~ s/&#(\d*);/chr($1)/ge;
	
	return $data;
	#return Slim::Utils::Misc::utf8toLatin1($data);
}

sub getPlaylistTrackArray {
	my @playlist = ();
	my $curLine = getLine();
	$::d_itunes_verbose && msg("Starting parsing of playlist\n");
	if ($curLine ne '<array>') {
		warn "Unexpected $curLine in playlist track array while looking for <array>";
		return;
	}
		
	while (($curLine = getLine()) && ($curLine ne '</array>')) {

		if ($curLine ne '<dict>') {
			warn "Unexpected $curLine in playlist track array while looking for <dict>";
			return;
		}
		
		$curLine = getLine();
		
		if ($curLine ne '<key>Track ID</key>') {
			warn "Unexpected $curLine in playlist track array while looking for track id";
			return \@playlist;
		}
		my $value = getValue();
		if (defined($tracks{$value})) {
			push @playlist, $tracks{$value};
			$::d_itunes_verbose && msg("  pushing $value on to list: " . $tracks{$value} . "\n");
		} else {
			$::d_itunes_verbose && msg("  NOT pusing $value on to list, it's missing\n");
		}

		$curLine = getLine();
		if ($curLine ne '</dict>') {
			warn "Unexpected $curLine in playlist track array while looking for </dict>";
			return \@playlist;
		}
	}	
	
	$::d_itunes && msg("got a playlist array of " . scalar(@playlist) . " items\n");
	return \@playlist;
}

sub getLine {
	my $curLine;
	
	$ituneslibrary =~ /([^\n]*)\n/g;	
	
	$curLine = $1;
	
	if (!defined($curLine)) {
		return undef;
	}
	
	$curLine =~ s/^\s+//;
	$curLine =~ s/\s$//;
	
	$::d_itunes_verbose && msg("Got line: $curLine\n");
	return $curLine;
}

sub getDict {
	my $curLine;
	my $nextLine;
	my %dict;
	while ($curLine = getLine()) {
		my $key = undef;
		my $value = undef;
		if ($curLine =~ /<key>([^<]*)<\/key>/) {
			$key = $1;
			if ($key eq "Playlist Items") {
				$value = getPlaylistTrackArray();
			} else {
				$value = getValue();
			}			
			if (defined($key) && defined($value)) { 
				$dict{$key} = $value;
				$::d_itunes_verbose && msg("got dictionary entry: $key = $value\n");
			} else {
				warn "iTunes: Couldn't get key and value in dictionary, got $key and $value";
			}
		} elsif ($curLine eq '<dict>') {
			$::d_itunes_verbose && msg("found beginning of dictionary\n");
		} elsif ($curLine eq '</dict>') {
			$::d_itunes_verbose && msg("found end of dictionary\n");
			last;
		} else {
			warn "iTunes: Confused looking for key in dictionary";
		}
	}
	return %dict;
}

sub resetScanState {
	$inPlaylists = 0;
	$inTracks = 0;
	$applicationVersion = undef;
	$majorVersion = undef;
	$minorVersion = undef;
	%tracks = ();
}

sub strip_automounter {
	my $path = shift;
	if ($path && ($path =~ /automount/)) {
		#Strip out automounter 'private' paths.
		#OSX wants us to use file://Network/ or timeouts occur
		#There may be more combinations
		$path =~ s/private\/var\/automount\///;
		$path =~ s/private\/automount\///;
		$path =~ s/automount\/static\///;
	}
	
	#remove trailing slash
	$path && $path =~ s/\/$//;

	return $path;
}

sub setupGroup {
	my $client = shift;
	my %setupGroup = (
		'PrefOrder' => ['itunes']
		,'PrefsInTable' => 1
		,'Suppress_PrefHead' => 1
		,'Suppress_PrefDesc' => 1
		,'Suppress_PrefLine' => 1
		,'Suppress_PrefSub' => 1
		,'GroupHead' => string('SETUP_ITUNES')
		,'GroupDesc' => string('SETUP_ITUNES_DESC')
		,'GroupLine' => 1
				,'GroupSub' => 1
	);
	my %setupPrefs = (
		'itunes'	=> {
			'validate' => \&Slim::Web::Setup::validateTrueFalse
			,'changeIntro' => ""
			,'options' => {
					'1' => string('USE_ITUNES')
					,'0' => string('DONT_USE_ITUNES')
				}
			,'onChange' => 	sub {
					my ($client,$changeref,$paramref,$pageref) = @_;

					foreach my $client (Slim::Player::Client::clients()) {
						Slim::Buttons::Home::updateMenu($client);
					}
					Slim::Music::Import::useImporter('itunes',$changeref->{'itunes'}{'new'});
					Slim::Music::Import::startScan('itunes');
				}
			,'optionSort' => 'KR'
			,'inputTemplate' => 'setup_input_radio.html'
		}
	);
	return (\%setupGroup,\%setupPrefs);
}

sub checkDefaults {
	if (!Slim::Utils::Prefs::isDefined('itunesscaninterval')) {
		Slim::Utils::Prefs::set('itunesscaninterval',60)
	}
	if (!Slim::Utils::Prefs::isDefined('iTunesplaylistprefix')) {
		Slim::Utils::Prefs::set('iTunesplaylistprefix','iTunes: ');
	}
	if (!Slim::Utils::Prefs::isDefined('iTunesplaylistsuffix')) {
		Slim::Utils::Prefs::set('iTunesplaylistsuffix','');
	}
	if (!Slim::Utils::Prefs::isDefined('ignoredisableditunestracks')) {
		Slim::Utils::Prefs::set('ignoredisableditunestracks',0);
	}
	if (!Slim::Utils::Prefs::isDefined('itunes_library_music_path')) {
		Slim::Utils::Prefs::set('itunes_library_music_path',Slim::Utils::Prefs::defaultAudioDir());
	}
	if (!Slim::Utils::Prefs::isDefined('itunes_library_autolocate')) {
		Slim::Utils::Prefs::set('itunes_library_autolocate',1);
	}
}

sub setupCategory {
	my %setupCategory =(
		'title' => string('SETUP_ITUNES')
		,'parent' => 'server'
		,'GroupOrder' => ['Default','iTunesPlaylistFormat']
		,'Groups' => {
			'Default' => {
					'PrefOrder' => ['itunesscaninterval','ignoredisableditunestracks','itunes_library_autolocate','itunes_library_xml_path','itunes_library_music_path']
				}
			,'iTunesPlaylistFormat' => {
					'PrefOrder' => ['iTunesplaylistprefix','iTunesplaylistsuffix']
					,'PrefsInTable' => 1
					,'Suppress_PrefHead' => 1
					,'Suppress_PrefDesc' => 1
					,'Suppress_PrefLine' => 1
					,'Suppress_PrefSub' => 1
					,'GroupHead' => string('SETUP_ITUNESPLAYLISTFORMAT')
					,'GroupDesc' => string('SETUP_ITUNESPLAYLISTFORMAT_DESC')
					,'GroupLine' => 1
					,'GroupSub' => 1
				}
			}
		,'Prefs' => {
			'itunesscaninterval' => {
					'validate' => \&Slim::Web::Setup::validateNumber
					,'validateArgs' => [0,undef,1000]
				}
			,'iTunesplaylistprefix' => {
					'validate' => \&Slim::Web::Setup::validateAcceptAll
					,'PrefSize' => 'large'
				}
			,'iTunesplaylistsuffix' => {
					'validate' => \&Slim::Web::Setup::validateAcceptAll
					,'PrefSize' => 'large'
				}
			,'ignoredisableditunestracks' => {
					'validate' => \&Slim::Web::Setup::validateTrueFalse
					,'options' => {
							'1' => string('SETUP_IGNOREDISABLEDITUNESTRACKS_1')
							,'0' => string('SETUP_IGNOREDISABLEDITUNESTRACKS_0')
						}
				}
			,'itunes_library_xml_path' => {
					'validate' => \&Slim::Web::Setup::validateIsFile
					,'changeIntro' => string('SETUP_OK_USING')
					,'rejectMsg' => string('SETUP_BAD_FILE')
					,'PrefSize' => 'large'
				}
			,'itunes_library_music_path' => {
					'validate' => \&Slim::Web::Setup::validateIsDir
					,'changeIntro' => string('SETUP_OK_USING')
					,'rejectMsg' => string('SETUP_BAD_DIRECTORY')
					,'PrefSize' => 'large'
				}
			,'itunes_library_autolocate' => {
					'validate' => \&Slim::Web::Setup::validateTrueFalse
					,'options' => {
							'1' => string('SETUP_ITUNES_LIBRARY_AUTOLOCATE_1')
							,'0' => string('SETUP_ITUNES_LIBRARY_AUTOLOCATE_0')
						}
				}
		}
	);
	return (\%setupCategory);
};
1;
__END__

