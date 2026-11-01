# frozen_string_literal: true

require 'spec_helper_acceptance'

# Read as an unprivileged user; dconf reads compiled dbs directly, no session bus needed
def dconf_read(key, profile = nil)
  env = profile ? "DCONF_PROFILE=#{profile} " : ''
  run_shell("su - dconftest -c '#{env}dconf read #{key}'").stdout.strip
end

def manifest(picture_uri)
  <<~MANIFEST
    class { 'dconf':
      profiles => {
        'user' => {
          'entries' => {
            'user'  => { 'type' => 'user', 'order' => 10 },
            'local' => { 'type' => 'system', 'order' => 21 },
          },
        },
      },
      dbs      => {
        'local' => {
          'settings' => {
            'org/gnome/desktop/background' => {
              'picture-uri' => "'#{picture_uri}'",
            },
            'org/gnome/shell'              => {
              'favorite-apps' => "['a.desktop','b.desktop']",
            },
            'org/gnome/desktop/session'    => {
              'idle-delay' => 'uint32 0',
            },
            'org/gnome/software'           => {
              'allow-updates' => false,
            },
          },
          'locks'    => [
            '/org/gnome/desktop/background/picture-uri',
          ],
        },
      },
    }
  MANIFEST
end

describe 'dconf' do
  before(:all) do
    run_shell('id dconftest || useradd -m dconftest')
  end

  context 'with a profile and a db with settings and locks' do
    it 'applies idempotently' do
      idempotent_apply(manifest('file:///usr/share/backgrounds/one.png'))
    end

    describe file('/etc/dconf/profile/user') do
      its(:content) { is_expected.to eq("user-db:user\nsystem-db:local\n") }
    end

    describe file('/etc/dconf/db/local.d/00-local_default') do
      its(:content) { is_expected.to match(%r{^\[org/gnome/shell\]\nfavorite-apps = \['a.desktop','b.desktop'\]$}) }
    end

    describe file('/etc/dconf/db/local.d/locks/00-local_default') do
      its(:content) { is_expected.to match(%r{^/org/gnome/desktop/background/picture-uri$}) }
    end

    describe file('/etc/dconf/db/local') do
      it { is_expected.to be_file }
    end

    it 'compiles settings that dconf reads back through the profile' do
      expect(dconf_read('/org/gnome/desktop/background/picture-uri', 'user')).to eq("'file:///usr/share/backgrounds/one.png'")
      expect(dconf_read('/org/gnome/shell/favorite-apps', 'user')).to eq("['a.desktop', 'b.desktop']")
      expect(dconf_read('/org/gnome/desktop/session/idle-delay', 'user')).to eq('uint32 0')
      expect(dconf_read('/org/gnome/software/allow-updates', 'user')).to eq('false')
    end

    it 'uses the user profile by default' do
      expect(dconf_read('/org/gnome/shell/favorite-apps')).to eq("['a.desktop', 'b.desktop']")
    end

    it 'enforces locks over the user db' do
      run_shell(<<~CMD)
        su - dconftest -c 'mkdir -p ~/.config/dconf ~/user.d && printf "%s\\n" \
          "[org/gnome/desktop/background]" "picture-uri='\\''file:///user.png'\\''" \
          "[org/gnome/shell]" "favorite-apps=['\\''user.desktop'\\'']" > ~/user.d/user && \
          dconf compile ~/.config/dconf/user ~/user.d'
      CMD
      expect(dconf_read('/org/gnome/desktop/background/picture-uri')).to eq("'file:///usr/share/backgrounds/one.png'")
      expect(dconf_read('/org/gnome/shell/favorite-apps')).to eq("['user.desktop']")
    ensure
      run_shell('rm -rf ~dconftest/.config/dconf ~dconftest/user.d')
    end
  end

  context 'when a setting changes' do
    it 'applies idempotently' do
      idempotent_apply(manifest('file:///usr/share/backgrounds/two.png'))
    end

    it 'recompiles the db' do
      expect(dconf_read('/org/gnome/desktop/background/picture-uri')).to eq("'file:///usr/share/backgrounds/two.png'")
    end
  end

  context 'with ensure => absent' do
    it 'applies idempotently' do
      idempotent_apply(<<~MANIFEST)
        class { 'dconf':
          profiles => { 'user' => { 'ensure' => 'absent' } },
          dbs      => { 'local' => { 'ensure' => 'absent' } },
        }
      MANIFEST
    end

    describe file('/etc/dconf/profile/user') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/dconf/db/local.d') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/dconf/db/local') do
      it { is_expected.not_to exist }
    end

    it 'no longer returns the setting' do
      expect(dconf_read('/org/gnome/shell/favorite-apps', 'user')).to be_empty
    end
  end
end
