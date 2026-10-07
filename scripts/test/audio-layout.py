#!/usr/bin/python3
"""Regression checks for ALSA capability selection and SteamOS policy overrides."""
from pathlib import Path
import runpy

module = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'guest/layer/usr/lib/steamac/audio-layout'))
select = module['playback_map']
config = module['configuration']
assert select(' | chmap-fixed=MONO\n | chmap-fixed=FL,FR\n') == ['FL', 'FR']
height = 'FL FR FC LFE SL SR TSL TSR'.split()
assert select(' | chmap-fixed=FL,FR\n | chmap-fixed=' + ','.join(height)) == height
assert select(' | chmap-fixed=FL,FR,BAD\n') == []
assert select(' | chmap-fixed=FL,FR,RL,RR,FC,LFE,SL,SR,RC,FLC,FRC,TC,TFL\n') == []
assert select(' : values=0,0,0,0\n') == []
text = config(height)
assert 'audio.channels = 8' in text and 'audio.position = [ FL FR FC LFE SL SR TSL TSR ]' in text
assert 'device.profile = "pro-audio"' in text and 'api.acp.disable-pro-audio = false' in text
assert 'api.alsa.use-chmap = true' in text and 'api.alsa.card.name = "VirtIO SoundCard"' in text
assert text.count('api.alsa.disable-tsched = false') == 2
assert text.count('api.alsa.auto-link = false') == 2
assert 'node.group = "steamac-playback"' in text and 'node.group = "steamac-capture"' in text
print('audio-layout: stereo, 5.1.2, malformed/missing maps and policy checks passed')
surround = 'FL FR RL RR FC LFE SL SR TFL TFR TRL TRR'.split()
assert select(' | chmap-fixed=' + ','.join(surround)) == surround
assert 'audio.channels = 12' in config(surround)
assert 'audio.position = [ ' + ' '.join(surround) + ' ]' in config(surround)
assert select(' | chmap-fixed=FL,FL\n') == []
print('audio-layout: 7.1.4 and twelve-channel limit checks passed')
