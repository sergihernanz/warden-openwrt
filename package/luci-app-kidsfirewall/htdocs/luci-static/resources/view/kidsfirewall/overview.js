'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require network';

var SAFE_DNS_LABELS = {
	off: _('Off'),
	cleanbrowsing: _('CleanBrowsing (Family Filter)'),
	opendns: _('OpenDNS FamilyShield'),
	cloudflare: _('Cloudflare for Families'),
	custom: _('Custom')
};

return view.extend({
	load: function() {
		// make sure our config is fully loaded before render() enumerates
		// its 'device'/'service' sections to populate the rule dropdowns,
		// and fetch the Safe DNS drift-check status kidsfirewall-monitor
		// refreshes every tick ("<off|ok|drifted>:<provider>", or missing
		// entirely before the service has ever run once)
		return Promise.all([
			uci.load('kidsfirewall'),
			L.resolveDefault(fs.read('/var/run/kidsfirewall/safe_dns_status'), ''),
			network.getHostHints()
		]);
	},

	render: function(data) {
		var m, s, o;
		var safeDnsStatus = (data[1] || '').trim().split(':');
		var safeDnsState = safeDnsStatus[0] || '';
		var safeDnsProvider = safeDnsStatus[1] || '';
		var hosts = data[2];

		m = new form.Map('kidsfirewall', _('Kids Firewall'),
			_('Block, time-budget, or schedule internet access for specific ' +
			  'devices and services. Changes apply after Save & Apply.'));

		// ---------------------------------------------------------- General
		s = m.section(form.TypedSection, 'global', _('General Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'check_interval', _('Check interval (seconds)'),
			_('How often the monitor daemon re-evaluates schedules and time budgets.'));
		o.datatype = 'range(10,3600)';
		o.default = '60';
		o.rmempty = false;

		// --------------------------------------------------------- Safe DNS
		var safeDnsDesc = _('Network-wide filtered upstream DNS resolver — applies to ' +
			'every device on the LAN, independent of the per-device rules below.');
		if (safeDnsState === 'drifted') {
			safeDnsDesc = _('⚠ Safe DNS is set to "%s" but the live DHCP/DNS ' +
				'configuration no longer matches it — likely changed manually since ' +
				'it was last applied here. Traffic may not be filtered right now. ' +
				'Use "Reapply now" below to restore it.').format(
					SAFE_DNS_LABELS[safeDnsProvider] || safeDnsProvider);
		}

		s = m.section(form.TypedSection, 'global', _('Safe DNS'), safeDnsDesc);
		s.anonymous = true;
		s.addremove = false;

		var safeDns = s.option(form.ListValue, 'safe_dns', _('Provider'));
		safeDns.rmempty = false;
		safeDns.default = 'off';
		Object.keys(SAFE_DNS_LABELS).forEach(function(key) {
			safeDns.value(key, SAFE_DNS_LABELS[key]);
		});

		var safeDnsServer = s.option(form.DynamicList, 'safe_dns_server',
			_('Custom resolver addresses'));
		safeDnsServer.depends('safe_dns', 'custom');
		safeDnsServer.optional = true;

		var reapply = s.option(form.Button, '_safe_dns_reapply', '');
		reapply.inputtitle = _('Reapply Safe DNS now');
		reapply.inputstyle = safeDnsState === 'drifted' ? 'negative' : 'primary';
		reapply.onclick = function(ev) {
			return fs.exec('/usr/sbin/kidsfirewall-safe-dns-reapply', []).then(function() {
				location.reload();
			});
		};

		var forceDns = s.option(form.Flag, 'force_dns',
			_('Force router DNS (block DNS bypass)'),
			_('Redirects every device\'s DNS traffic (port 53) back to this ' +
			  'router, regardless of what DNS server any device is configured ' +
			  'to use — closes the gap a device with a manually-set external ' +
			  'DNS server would otherwise have to slip through every rule above ' +
			  'and Safe DNS. Does not stop DNS-over-HTTPS (indistinguishable ' +
			  'from ordinary HTTPS traffic).'));
		forceDns.rmempty = false;
		forceDns.default = '0';

		// ---------------------------------------------------------- Devices
		s = m.section(form.TypedSection, 'device', _('Devices'),
			_('The devices (by MAC address) you want to apply rules to.'));
		s.anonymous = true;
		s.addremove = true;
		// Anonymous sections display without the "type a UCI identifier"
		// prompt, but their auto-generated cfgXXXXXXXX id is only a
		// positional counter -- adding/removing ANY anonymous section
		// elsewhere in the file can silently reassign it, orphaning any
		// rule that references it by that id (confirmed on a real router:
		// rules pointed at ids that no longer matched anything after
		// routine edits). Overriding handleAdd creates a genuinely NAMED
		// section instead (stable forever) with an auto-generated id, so
		// there's still no identifier-typing prompt, but nothing can drift.
		s.handleAdd = function(ev) {
			var name = 'dev_' + Math.random().toString(36).slice(2, 10);
			this.map.data.add(this.uciconfig || this.map.config, this.sectiontype, name);
			return this.map.save(null, true);
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'mac', _('MAC Address'),
			_('Pick a device the router has already seen, or type a MAC address ' +
			  'manually if yours isn\'t listed (e.g. it\'s only ever shown up over ' +
			  'IPv6 with no resolved link-layer address yet).'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		o.placeholder = 'AA:BB:CC:DD:EE:FF';
		// Suggestions only -- calling .value() turns this from a plain text
		// field into a combobox (pick from the list OR still type your own),
		// never a hard restriction to what's listed. A device with no MAC
		// known to the router at all (e.g. IPv6-only, neighbor discovery
		// never resolved a link-layer address for it) simply won't appear
		// here and still needs to be typed in manually.
		hosts.getMACHints().forEach(function(hint) {
			o.value(hint[0], hint[1] ? hint[0] + ' (' + hint[1] + ')' : hint[0]);
		});

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		// --------------------------------------------------------- Services
		s = m.section(form.TypedSection, 'service', _('Services'),
			_('Named services and the domains that identify their traffic. ' +
			  'Ships with common defaults; add your own as needed.'));
		s.anonymous = true;
		s.addremove = true;
		// same stable-naming fix as the Devices section above
		s.handleAdd = function(ev) {
			var name = 'svc_' + Math.random().toString(36).slice(2, 10);
			this.map.data.add(this.uciconfig || this.map.config, this.sectiontype, name);
			return this.map.save(null, true);
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'domain', _('Domains'),
			_('e.g. instagram.com — matches this domain and its subdomains.'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'cidr', _('Static IPv4 ranges (optional)'),
			_('Advanced/optional backstop for devices that bypass this router’s ' +
			  'DNS. Empty by default — see ARCHITECTURE.md before populating this.'));
		o.optional = true;

		// ------------------------------------------------------------ Rules
		s = m.section(form.TypedSection, 'rule', _('Rules'),
			_('What to do for a given device: block a service outright, cap it ' +
			  'to a daily/weekly time budget, or restrict the device to an ' +
			  'allowed time window.'));
		s.anonymous = true;
		s.addremove = true;

		var device = s.option(form.ListValue, 'device', _('Device'));
		device.rmempty = false;
		uci.sections('kidsfirewall', 'device', function(sec) {
			device.value(sec['.name'], sec.name || sec['.name']);
		});

		var mode = s.option(form.ListValue, 'mode', _('Mode'));
		mode.rmempty = false;
		mode.value('block', _('Block'));
		mode.value('budget', _('Time budget'));
		mode.value('schedule', _('Schedule (whole device)'));

		var service = s.option(form.ListValue, 'service', _('Service'));
		uci.sections('kidsfirewall', 'service', function(sec) {
			service.value(sec['.name'], sec.name || sec['.name']);
		});
		service.depends('mode', 'block');
		service.depends('mode', 'budget');

		var limit = s.option(form.Value, 'limit_minutes', _('Limit (minutes)'));
		limit.datatype = 'uinteger';
		limit.placeholder = '30';
		limit.depends('mode', 'budget');

		var period = s.option(form.ListValue, 'period', _('Resets'));
		period.value('daily', _('Daily'));
		period.value('weekly', _('Weekly'));
		period.default = 'daily';
		period.depends('mode', 'budget');

		var start_time = s.option(form.Value, 'start_time', _('Allowed from'));
		start_time.placeholder = '08:00';
		start_time.depends('mode', 'schedule');

		var stop_time = s.option(form.Value, 'stop_time', _('Allowed until'));
		stop_time.placeholder = '20:00';
		stop_time.depends('mode', 'schedule');

		var days = s.option(form.MultiValue, 'days', _('Active days'), _('Leave empty for every day'));
		days.optional = true;
		days.value('mon', _('Mon'));
		days.value('tue', _('Tue'));
		days.value('wed', _('Wed'));
		days.value('thu', _('Thu'));
		days.value('fri', _('Fri'));
		days.value('sat', _('Sat'));
		days.value('sun', _('Sun'));
		days.depends('mode', 'schedule');

		return m.render();
	}
});
