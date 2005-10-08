# Plugin for Slimserver to monitor Server and Network Health

# $Id$

# This code is derived from code with the following copyright message:
#
# SlimServer Copyright (C) 2005 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

package Plugins::Health::Plugin;

use strict;

use vars qw($VERSION);
$VERSION = "0.01";

use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

sub clearAllCounters {
	
	foreach my $client (Slim::Player::Client::clients()) {
		$client->signalStrengthLog()->clear();
		$client->bufferFullnessLog()->clear();
		$client->slimprotoQLenLog()->clear();
	}
	$Slim::Networking::Select::selectPerf->clear();
	$Slim::Networking::Select::endSelectTime = undef;
	$Slim::Utils::Timers::timerLate->clear();
	$Slim::Utils::Timers::timerLength->clear();
	$Slim::Utils::Scheduler::schedulerPerf->clear();
}
	
sub summary {
	my $client = shift;
	
	my ($summary, $error);

	if (defined($client) && $client->isa("Slim::Player::Squeezebox")) {

		my ($control, $stream, $signal, $buffer);

		if ($client->tcpsock() && $client->tcpsock()->opened()) {
			if ($client->slimprotoQLenLog()->percentAbove(2) < 5) {
				$control = string("PLUGIN_HEALTH_OK");
			} else {
				$control = string("PLUGIN_HEALTH_CONGEST");
				$error .= string("PLUGIN_HEALTH_CONTROLCONGEST_DESC");
			}
		} else {
			$control = string("PLUGIN_HEALTH_FAIL");
			$error .= string("PLUGIN_HEALTH_CONTROLFAIL_DESC");
		}

		if ($client->streamingsocket() && $client->streamingsocket()->opened()) {
			$stream = string("PLUGIN_HEALTH_OK");
		} else {
			$stream = string("PLUGIN_HEALTH_INACTIVE");
			$error .= string("PLUGIN_HEALTH_STREAMINACTIVE_DESC");
		}

		if ($client->signalStrengthLog()->percentBelow(50) < 1) {
			$signal = string("PLUGIN_HEALTH_OK");
		} elsif ($client->signalStrengthLog()->percentBelow(50) < 5) {
			$signal = string("PLUGIN_HEALTH_SIGNAL_INTERMIT");
			$error .= string("PLUGIN_HEALTH_SIGNAL_INTERMIT_DESC");
		} elsif ($client->signalStrengthLog()->percentBelow(50) < 20) {
			$signal = string("PLUGIN_HEALTH_SIGNAL_POOR");
			$error .= string("PLUGIN_HEALTH_SIGNAL_POOR_DESC");
		} else {
			$signal = string("PLUGIN_HEALTH_SIGNAL_BAD");
			$error .= string("PLUGIN_HEALTH_SIGNAL_BAD_DESC");
		}

		$summary .= sprintf "%-22s : %s\n", string('PLUGIN_HEALTH_CONTROL'), $control;
		$summary .= sprintf "%-22s : %s\n", string('PLUGIN_HEALTH_STREAM'), $stream;
		$summary .= sprintf "%-22s : %s\n", string('PLUGIN_HEALTH_SIGNAL'), $signal;

		if (Slim::Player::Source::playmode($client) eq 'play') {

			if ($client->isa("Slim::Player::Squeezebox2")) {
				if ($client->bufferFullnessLog()->percentBelow(30) < 15) {
					$buffer = string("PLUGIN_HEALTH_OK");
				} else {
					$buffer = string("PLUGIN_HEALTH_BUFFER_LOW");
					$error .= string("PLUGIN_HEALTH_BUFFER_LOW_DESC2");
				}
			} else {
				if ($client->bufferFullnessLog()->percentBelow(50) < 5) {
					$buffer = string("PLUGIN_HEALTH_OK");
				} else {
					$buffer = string("PLUGIN_HEALTH_BUFFER_LOW");
					$error .= string("PLUGIN_HEALTH_BUFFER_LOW_DESC1");
				}
			}			
			$summary .= sprintf "%-22s : %s\n", string('PLUGIN_HEALTH_BUFFER'), $buffer;
		}
	} elsif (defined($client) && $client->isa("Slim::Player::SLIMP3")) {
		$error .= string("PLUGIN_HEALTH_SLIMP3_DESC");
	} else {
		$error .= string("PLUGIN_HEALTH_NO_PLAYER_DESC");
	}

	if ($Slim::Networking::Select::selectPerf->above(1) < 5) {
		$summary .= sprintf "%-22s : %s\n", string("PLUGIN_HEALTH_RESPONSE"), string("PLUGIN_HEALTH_OK");
	} elsif ($Slim::Networking::Select::selectPerf->percentAbove(1) < 0.5) {
		$summary .= sprintf "%-22s : %s\n", string("PLUGIN_HEALTH_RESPONSE"), string("PLUGIN_HEALTH_RESPONSE_INTERMIT");
		$error .= string("PLUGIN_HEALTH_RESPONSE_INTERMIT_DESC");
	} else {
		$summary .= sprintf "%-22s : %s\n", string("PLUGIN_HEALTH_RESPONSE"), string("PLUGIN_HEALTH_RESPONSE_POOR");
		$error .= string("PLUGIN_HEALTH_RESPONSE_POOR_DESC");
	}

	return ($summary, $error);
}
	

sub webPages {
	my %pages = ("index\.(?:htm|xml)" => \&handleIndex);

	Slim::Web::Pages::addLinks("help", { 'PLUGIN_HEALTH' => "plugins/Health/index.html" });
	return (\%pages);
}

sub handleIndex {
	my ($client, $params) = @_;
	
	my $refresh = 30; # default refresh of 30s 

	if ($params->{'perf'}) {
		if ($params->{'perf'} eq 'on') {
			$::perfmon = 1;
			clearAllCounters();
		} elsif ($params->{'perf'} eq 'off') {
			$::perfmon = 0;
		}
		if ($params->{'perf'} eq 'clear') {
			clearAllCounters();
			$refresh = 2;
		}
	}
	
	if ($::perfmon) {
		$params->{'perfon'} = 1;
	} else {
		$params->{'perfoff'} = 1;
		$refresh = undef;
	}

	if (defined($client)) {
		$params->{'playername'} = $client->name();
		$params->{'signal'} = $client->signalStrengthLog()->sprint();
		$params->{'buffer'} = $client->bufferFullnessLog()->sprint();
		$params->{'control'} = $client->slimprotoQLenLog()->sprint();
	}

	$params->{'response'} = $Slim::Networking::Select::selectPerf->sprint();
	$params->{'timerlate'} = $Slim::Utils::Timers::timerLate->sprint();
	$params->{'timerlength'} = $Slim::Utils::Timers::timerLength->sprint();
	$params->{'scheduler'} = $Slim::Utils::Scheduler::schedulerPerf->sprint();

	($params->{'summary'}, $params->{'summary_error'}) = summary($client);

	$params->{'refresh'} = $refresh;

	return Slim::Web::HTTP::filltemplatefile('plugins/Health/index.html',$params);
}

sub getDisplayName {
	return('PLUGIN_HEALTH');
}

sub strings {
	return '
PLUGIN_HEALTH
	DE	Server & Netzwerk Zustand
	EN	Server & Network Health

PLUGIN_HEALTH_PERF_ENABLE
	DE	Leistungsüberwachung aktivieren
	EN	Enable Performance Monitoring

PLUGIN_HEALTH_PERF_DISABLE
	DE	Leistungsüberwachung deaktivieren
	EN	Disable Performance Monitoring

PLUGIN_HEALTH_PERF_CLEAR
	DE	Zähler zurücksetzen
	EN	Reset Counters

PLUGIN_HEALTH_PERF_UPDATE
	DE	Seite aktualisieren
	EN	Update Page

PLUGIN_HEALTH_PERFOFF_DESC
	DE	Die Leistungsüberwachung ist zurzeit nicht aktiviert.
	EN	Performance monitoring is not currently enabled on your server.

PLUGIN_HEALTH_PERFON_DESC
	DE	Die Leistungsüberwachung ist auf ihrem Server aktiviert. Der Server sammelt während der Ausführung Leistungsdaten.
	EN	Performance monitoring is currently enabled on your server.	Performance statistics are being collected in the background while your server is running.

PLUGIN_HEALTH_SUMMARY
	DE	Zusammenfassung
	EN	Summary

PLUGIN_HEALTH_SUMMARY_DESC
	DE	Bitte erstellen Sie eine Wiedergabeliste auf ihrem Player und starten Sie die Wiedergabe. Drücken Sie dann "Zähler zurücksetzen", um die Statistiken neu zu starten und die Anzeige zu aktualisieren. 
	EN	Please queue up several tracks to play on this player and start them playing.  Then press the Reset Counters link above to clear the statistics and update this display.

PLUGIN_HEALTH_PLAYERDETAIL
	DE	Player-Leistung
	EN	Player Performance

PLUGIN_HEALTH_PLAYERDETAIL_DESC
	DE	Die folgenden Graphen zeigen den Langzeit-Trend für alle Player-Leistungsdaten auf. Sie zeigen die Anzahl und den Prozentanteil der Messungen, die in eine bestimmte Wertekategorie fallen.<p>Es ist wichtig, den Player eine Weile Musik spielen zu lassen, um aussagekräftige Werte zu erhalten.
	EN	The graphs shown here record the long term trend for each of the player performance measurements below.  They display the number and percentage of measurements which fall within each measurement band.<p>It is imporant to leave the player playing for a while and then assess the graphs.

PLUGIN_HEALTH_SIGNAL
	DE	Signalstärke
	EN	Player Signal Strength

PLUGIN_HEALTH_SIGNAL_DESC
	DE	Diese Graphik zeigt die Signalstärke der Wireless Netzwerkverbindung ihres Players. Höhere Werte sind besser. Der Player gibt die Signalstärke während der Wiedergabe zurück.
	EN	This graph shows the strength of the wireless signal received by your player.  Higher signal strength is better.  The player reports signal strength while it is playing.

PLUGIN_HEALTH_BUFFER
	DE	Puffer-Füllstand
	EN	Buffer Fullness

PLUGIN_HEALTH_BUFFER_DESC
	DE	Diese Graphik zeigt den Puffer-Füllstand ihres Players. Höhere Werte sind besser. Beachten Sie bitte, dass der Puffer nur während der Wiedergabe gefüllt wird.<p>Die Squeezebox1 besitzt nur einen kleinen Puffer, der während der Wiedergabe stets voll sein sollte. Fällt der Wert auf 0, so ist mit Aussetzern in der Wiedergabe zu rechnen. Dies wäre vermutlich auf Netzwerkprobleme zurückzuführen.<p>Die Squeezebox2 verwendet einen grossen Puffer. Dieser wird am Ende jedes wiedergegebenen Liedes geleert (Füllstand 0) um dann wieder aufzufüllen. Der Füllstand sollte also meist hoch sein.<p>Die Wiedergabe von Online-Radiostationen kann zu niedrigem Puffer-Füllstand führen, da der Player auf die Daten von einem entfernten Server warten muss. Dies ist normales Verhalten und kein Grund zur Beunruhigung. 
	EN	This graph shows the fill of the player\'s buffer.  Higher buffer fullness is better.  Note the buffer is only filled while the player is playing tracks.<p>Squeezebox1 uses a small buffer and it is expected to stay full while playing.  If this value drops to 0 it will result in audio dropouts.  This is likely to be due to network problems.<p>Squeezebox2 uses a large buffer.  This drains to 0 at the end of each track and then refills for the next track.  You should only be concerned if the buffer fill is not high for the majority of the time a track is playing.<p>Playing remote streams can lead to low buffer fill as the player needs to wait for data from the remote server.  This is not a cause for concern.

PLUGIN_HEALTH_CONTROL
	DE	Kontrollverbindung
	EN	Control Connection

PLUGIN_HEALTH_CONTROL_DESC
	DE	Diese Graphik zeigt die Anzahl von aufgestauten Meldungen, die über die Kontroll-Verbindung zum Player geschickt werden sollten. Die Messung findet statt, wenn eine Meldung zum Player geschickt wird. Werte über 1-2 weisen auf eine mögliche Netzwerk-Überlastung hin, oder dass die Verbindung zum Player unterbrochen wurde.
	EN	This graph shows the number of messages queued up to send to the player over the control connection.  A measurement is taken every time a new message is sent to the player.  Values above 1-2 indicate potential network congestion or that the player has become disconnected.

PLUGIN_HEALTH_STREAM
	DE	Streaming-Verbindung
	EN	Streaming Connection

PLUGIN_HEALTH_SERVER_PERF
	DE	Server-Leistung
	EN	Server Performance

PLUGIN_HEALTH_SERVER_PERF_DESC
	DE	Die folgenden Graphen zeigen den Langzeit-Trend für alle Server-Leistungsdaten auf. Sie zeigen die Anzahl und den Prozentanteil der Messungen, die in eine bestimmte Wertekategorie fallen.
	EN	The graphs shown here record the long term trend for each of the server performance measurements below.  They display the number and percentage of measurements which fall within each measurement band.

PLUGIN_HEALTH_TIMER_LATE
	DE	Timer Genauigkeit
	EN	Timer Accuracy

PLUGIN_HEALTH_TIMER_LATE_DESC
	DE	SlimServer benutzt einen Timer, um Ereignisse wie z.B. Updates der Programmoberfläche zu steuern. Diese Graphik zeigt die Genauigkeit, mit welcher Timer-gesteuerte Abläufe im Vergleich zum vorgesehenen zeitlichen Ablauf ausgeführt werden. Die Masseinheit ist Sekunden.<p>Aufgaben werden auf einen bestimmten Zeitpunkt festgelegt. Da stets nur ein Timer ablaufen kann und der Server auch andere Aktivitäten ausführt, kommt es stets zu einer minimalen Verzögerung. Kommt es allerdings zu einer markanten Verzögerung, so kann es zu wahrnehmbaren Störungen der Benutzeroberfläche kommen. 
	EN	Slimserver uses a timer mechanism to trigger events such as updating the user interface.  This graph shows how accurately each timer task is run relative to the time it was intended to be run.  It is measured in seconds.<p>Timer tasks are scheduled by the server to run at some point in the future.  As only one timer task can run at once and the server may also be performing other activity, timer tasks always run slightly after the time they are scheduled for.  However if timer tasks run significantly after they are scheduled this can become noticable through delay in the user interface.

PLUGIN_HEALTH_TIMER_LENGTH
	DE	Timer Ausführungsdauer 
	EN	Timer Task Duration

PLUGIN_HEALTH_TIMER_LENGTH_DESC
	DE	Diese Graphik zeigt die Dauer, während der Timer-gesteuerte Abläufe ausgeführt werden. Die Masseinheit ist Sekunden. Braucht ein Vorgang länger als 0.5 Sekunden, so führt das mit grosser Wahrscheinlichkeit zu Störungen der Benutzeroberfläche.  
	EN	This graph shows how long each timer task runs for.  It is measured in seconds.  If any timer task takes more than 0.5 seconds this is likely to impact the user interface.

PLUGIN_HEALTH_RESPONSE
	DE	Server Antwortzeiten
	EN	Server Response Time

PLUGIN_HEALTH_RESPONSE_DESC
	DE	Diese Graphik zeigt die Zeitdauer, die zwischen zwei Anfragen von beliebigen Playern vergeht. Die Masseinheit ist Sekunden. Geringere Werte sind besser. Antwortzeiten über einer Sekunde können zu Problemen bei der Audio-Wiedergabe führen.<p>Gründe für solche Verzögerungen können andere ausgeführte Programme oder komplexe Verarbeitungen im SlimServer sein.
	EN	This graph shows the length of time between slimserver responding to requests from any player.  It is measured in seconds. Lower numbers are better.  If you notice response times of over 1 second this could lead to problems with audio performance.<p>The cause of long response times could be either other programs running on the server or slimserver processing a complex task.

PLUGIN_HEALTH_SCHEDULER
	DE	Geplante Aufgaben
	EN	Scheduled Tasks

PLUGIN_HEALTH_SCHEDULER_DESC
	DE	Der Server führt Prozessor-intensive Aufgaben wie z.B. das Durchsuchen nach neuen Musikstücken in Etappen aus, welche zwischen Anfragen von Playern durchgeführt werden. Diese Graphik zeigt die Länge in Sekunden, die eine Ausführung dauert, bevor der Server die Kontrolle wieder übernehmen kann. Aufgaben, welche länger als 0.5 Sekunden dauern, können zu Störungen der Benutzeroberfläche führen. 
	EN	The server runs processor intensive tasks (such as scanning your music collection) by breaking them into short pieces which are scheduled when when active players are not requesting data.  This graph shows the length of time in seconds that a scheduled task runs for before returning control to the server.  Tasks taking over 0.5 second may lead to reduced performance for the user interface.

PLUGIN_HEALTH_WARNINGS
	DE	Warnungen
	EN	Warnings

PLUGIN_HEALTH_OK
	EN	OK

PLUGIN_HEALTH_FAIL
	DE	Gestört
	EN	Fail

PLUGIN_HEALTH_CONGEST
	DE	Überlastung
	EN	Congested

PLUGIN_HEALTH_INACTIVE
	DE	Inaktiv
	EN	Inactive

PLUGIN_HEALTH_STREAMINACTIVE_DESC
	DE	Derzeit ist keine aktive Verbindung für diesen Player vorhanden. Eine Verbindung wird aufgebaut, wenn Sie eine Datei vom Server wiedergeben, nicht aber, wenn Sie eine Internet Radio-Station af einer Squeezebox2 hören.<p>Falls Sie versuchen, eine lokale Datei auf diesem Player abzuspielen, so deutet dies auf ein Netzwerkproblem hin. Bitte überprüfen Sie die Netzwerkkonfiguration und/oder Firewall (TCP Port 900 darf nicht blockiert sein).
	EN	There is currently no active connection for streaming to this player.  A connection is required whenever you play a file from the server (but not when you play remote radio streams on a Squeezebox2 player).<p>If you are attempting to play a local file on this player, then this indicates a network problem.  Please check that your network and/or server firewall do not block connections to TCP port 9000.<p>

PLUGIN_HEALTH_CONTROLFAIL_DESC
	DE	Derzeit ist keine aktive Kontroll-Verbindung für diesen Player vorhanden. Bitte stellen Sie sicher, dass das Gerät eingeschaltet ist. Falls der Player keine Netzwerkverbindung aufbauen kann, überprüfen sie bitte die Netzwerkkonfiguration und/oder Firewall. Diese darf TCP und UPD Ports 3483 nicht blockieren.<p> 
	EN	There is no currently active control connection to this player.  Please check the player is powered on.  If the player is unable to establish a connection, please check your network and and/or server firewall do not block connections to TCP & UDP port 3483.<p>

PLUGIN_HEALTH_CONTROLCONGEST_DESC
	DE	Die Kontroll-Verbindung zu diesem Player hat Überlastungen erfahren. Dies ist üblicherweise ein Hinweis auf schlechte Netzwerkverbindung, oder dass das Gerät vor kurzem vom Netz genommen wurde.<p>
	EN	The control connection to this player has experienced congestion.  This usually is an indication of poor network connectivity (or the player being recently being disconnected from the network).<p>

PLUGIN_HEALTH_SIGNAL_INTERMIT
	DE	Gut, aber mit vereinzelten Ausfällen 
	EN	Good, but Intermittent Drops

PLUGIN_HEALTH_SIGNAL_INTERMIT_DESC
	DE	Die Signalstärke dieses Players ist im Grossen und Ganzen gut, hatte aber vereinzelte Ausfälle. Dies kann auf andere Wireless Netzwerke, kabellose Telephone oder Mikrowellen-Öfen zurückzuführen sein. Falls Sie vereinzelte Ton-Aussetzer wahrnehmen, so sollten Sie der Ursache des Problems nachgehen.<p>
	EN	The signal strength received by this player is normally good, but occasionally drops.  This may be caused by other wireless networks, cordless phones or microwaves nearby.  If you hear occasional audio dropouts on this player, you should investigate what is causing drops in signal strength.<p>

PLUGIN_HEALTH_SIGNAL_POOR
	DE	Schwach
	EN	Poor

PLUGIN_HEALTH_SIGNAL_POOR_DESC
	DE	Die Signalstärke dieses Players ist grösstenteils schwach. Bitte überprüfen Sie das Wireless Netzwerk.<p>
	EN	The signal strength received by this player is poor for significant periods, please check your wireless network.<p>

PLUGIN_HEALTH_SIGNAL_BAD
	DE	Schlecht
	EN	Bad

PLUGIN_HEALTH_SIGNAL_BAD_DESC
	DE	Die Signalstärke dieses Players ist grösstenteils schlecht. Bitte überprüfen Sie das Wireless Netzwerk.<p>
	EN	The signal strength received by this player is bad for significant periods, please check your wireless network.<p>

PLUGIN_HEALTH_BUFFER_LOW
	DE	Niedrig
	EN	Low

PLUGIN_HEALTH_BUFFER_LOW_DESC1
	DE	Der Wiedergabe-Puffer dieses Players ist zeitweise niedriger als wünschenswert. Dies kann zu Tonaussetzern führen, v.a. falls Sie WAV oder AIFF verwenden. Falls Sie solche Aussetzer wahrnehmen, überprüfen Sie bitte die Signalstärke und Server Antwortzeiten.<p>
	EN	The playback buffer for this player is occasionally falling lower than ideal.  This may result in audio dropouts especually if you are streaming as WAV/AIFF.  If you are hearing these, please check your network signal strength and server response times.<p>

PLUGIN_HEALTH_BUFFER_LOW_DESC2
	DE	Der Wiedergabe-Puffer dieses Players ist zeitweise niedriger als wünschenswert. Dies ist eine Squeezebox2, es ist daher normal, dass der Puffer am Ende eines Liedes geleert wird. Diese Warnung wird ev. angezeigt, falls Sie viele kurze Lieder wiedergeben. Falls Sie Tonaussetzer feststellen, überprüfen Sie bitte die Signalstärke.<p>
	EN	The playback buffer for this player is occasionally falling lower than ideal.  This is a Squeezebox2 and so the buffer fullness is expected to drop at the end of each track.  You may see this warning if you are playing lots of short tracks.  If you are hearing audio dropouts, please check our network signal strength.<p>

PLUGIN_HEALTH_RESPONSE_INTERMIT
	DE	Teilweise schlechte Antwortzeiten
	EN	Occasional Poor Response

PLUGIN_HEALTH_RESPONSE_INTERMIT_DESC
	DE	Die Antwortzeiten des Servers sind zeitweise länger als wünschenswert. Dies kann zu hörbaren Tonaussetzern führen, v.a. auf SliMP3 und Squeezebox1 Playern. Gründe hierfür können andere laufene Programme im Hintergrund oder komplexe Aufgaben im Slimserver sein.<p>
	EN	Your server response time is occasionally longer than desired.  This may cause audio dropouts, especially on Slimp3 and Squeezebox1 players.  It may be due to background load on your server or a slimserver task taking longer than normal.<p>

PLUGIN_HEALTH_RESPONSE_POOR
	DE	Schlechte Antwortzeiten
	EN	Poor Response

PLUGIN_HEALTH_RESPONSE_POOR_DESC
	DE	Die Antwortzeiten des Servers sind oft länger als wünschenswert. Dies kann zu hörbaren Tonaussetzern führen, v.a. auf SliMP3 und Squeezebox1 Playern. Überprüfen Sie bitte die Leistung ihres Servers. Falls diese ok ist, vergewissern Sie sich, ob SlimServer komplexe Aufgaben (z.B. Durchsuchen der Musiksammlung) durchführt oder ein Plugin die Ursache für das Problem darstellt.
	EN	Your server response time is regularly falling below normal performance levels.  This may lead to audio dropouts, especially on Slimp3 and Squeezebox1 players.  Please check the performance of your server.  If this is OK, then check slimserver is not running intensive tasks (e.g. scanning music library) or a Plugin is not causing this.

PLUGIN_HEALTH_NORMAL
	DE	Dieser Player verhält sich normal.<p>
	EN	This player is performing normally.<p>

PLUGIN_HEALTH_NO_PLAYER_DESC
	DE	SlimServer kann keinen Player finden. Falls einer angeschlossen ist, so kann dies durch eine blockierte Netzwerkverbindung ausgelöst werden. Überprüfen sie bitte die Netzwerkkonfiguration und/oder Firewall. Diese darf TCP und UPD Ports 3483 nicht blockieren.<p>
	EN	Slimserver cannot find a player.  If you own a player this could be due to your network blocking connection between the player and server.  Please check your network and/or server firewall does not block connection to TCP & UDP port 3483.<p>

PLUGIN_HEALTH_SLIMP3_DESC
	DE	Sie verwenden einen SliMP3 Player. Für diesen stehen nicht die vollen Messungen zur Verfügung.<p>
	EN	This is a SLIMP3 player.  Full performance measurements are not available for this player.<p>

'
}

1;

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
