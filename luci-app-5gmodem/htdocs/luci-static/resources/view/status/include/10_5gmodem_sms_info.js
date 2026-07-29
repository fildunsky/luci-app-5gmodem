'use strict';
'require baseclass';
'require dom';
'require fs';
'require uci';
'require poll';
'require ui';

/*
	Copyright 2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/



/* See readsms.js: SMS via the mmcli wrapper for ModemManager-managed modems */
function smsToolBin() {
	return uci.get('5gmodem', 'sms', 'sms_via_mm') == '1' ? '/usr/share/5gmodem/sms_tool_mm' : '/usr/bin/sms_tool';
}

return baseclass.extend({
	title: _('Modems'),

	checkInterval: 12, // 12 × 5s = 60s

	restoreAlignmentSettings() {
		let alignment = localStorage.getItem('luci-modem-tiles-alignment');
		if (alignment === 'left' || alignment === 'center' || alignment === 'right') {
			return alignment;
		}
		return 'left';
	},

	saveAlignmentSettings(alignment) {
		localStorage.setItem('luci-modem-tiles-alignment', alignment);
	},

	getAlignmentStyle(alignment) {
		switch(alignment) {
			case 'center':
				return 'justify-content:center;';
			case 'right':
				return 'justify-content:flex-end;';
			default:
				return 'justify-content:flex-start;';
		}
	},

	showAlignmentModal(container) {
		let currentAlignment = this.restoreAlignmentSettings();
		
		let modalContent = E('div', {}, [
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:1em;' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, _('Align preview to:')),
						E('div', { 'class': 'cbi-value-field' }, [
							E('div', { 'style': 'display:flex;flex-direction:row;gap:20px;align-items:center;' }, [
								E('label', { 'style': 'display:flex;align-items:center;cursor:pointer;' }, [
									E('input', {
										'type': 'radio',
										'name': 'tile-alignment',
										'value': 'left',
										'id': 'align-left',
										'style': 'margin-right:6px;'
									}),
									E('span', {}, _('Left'))
								]),
								E('label', { 'style': 'display:flex;align-items:center;cursor:pointer;' }, [
									E('input', {
										'type': 'radio',
										'name': 'tile-alignment',
										'value': 'center',
										'id': 'align-center',
										'style': 'margin-right:6px;'
									}),
									E('span', {}, _('Center'))
								]),
								E('label', { 'style': 'display:flex;align-items:center;cursor:pointer;' }, [
									E('input', {
										'type': 'radio',
										'name': 'tile-alignment',
										'value': 'right',
										'id': 'align-right',
										'style': 'margin-right:6px;'
									}),
									E('span', {}, _('Right'))
								])
							])
						])
					])
				])
			])
		]);

		ui.showModal(_('New message information block settings'), [
			modalContent,
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': L.bind(function() {
						ui.hideModal();
					}, this)
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': L.bind(function() {
						let selectedAlignment = document.querySelector('input[name="tile-alignment"]:checked').value;
						this.saveAlignmentSettings(selectedAlignment);
						
						let alignmentStyle = this.getAlignmentStyle(selectedAlignment);
						container.style.cssText = 'display:flex;flex-wrap:wrap;gap:6px;' + alignmentStyle;
						
						ui.hideModal();
						ui.addTimeLimitedNotification(null, E('p', _('Alignment settings saved successfully')), 5000, 'info');
					}, this)
				}, _('Save'))
			])
		]);
		
		requestAnimationFrame(function() {
			let radioToCheck = document.getElementById('align-' + currentAlignment);
			if (radioToCheck) {
				radioToCheck.checked = true;
			}
		});
	},

	addStyles: function() {
		if (document.getElementById('modem-sms-styles')) return;
		
		const style = document.createElement('style');
		style.id = 'modem-sms-styles';
		style.type = 'text/css';
		style.textContent = `
			:root {
				--sms-badge-bg: #34c759;
				--sms-badge-text: #ffffff;
			}
			
			:root[data-darkmode="true"] {
				--sms-badge-bg: rgba(46, 204, 113, 0.66);
				--sms-badge-text: #e5e7eb;
			}
			
			.modem-sms-badge {
				position: absolute;
				top: -6px;
				right: -8px;
				background-color: var(--sms-badge-bg);
				color: var(--sms-badge-text);
				text-shadow: 0 1px 2px rgba(0,0,0,.4), 0 2px 6px rgba(0,0,0,.25);
				padding: 2px 5px;
				border-radius: 4px;
				min-width: 18px;
				text-align: center;
				white-space: nowrap;
				font-weight: 500;
				font-size: 11px;
				display: inline-block;
				border: 1px solid transparent;
				line-height: 1.3;
			}
			
			:root[data-darkmode="true"] .modem-sms-badge {
				background-color: var(--sms-badge-bg);
				border: 1px solid rgba(46, 204, 113, 0.6);
			}
			
			.sms-icon-no-messages img {
				opacity: 0.7;
			}
			
			.sms-icon-with-messages img {
				opacity: 1;
			}
			
			:root[data-darkmode="true"] .sms-icon-no-messages img,
			:root[data-darkmode="true"] .sms-icon-with-messages img {
				opacity: 0.5;
			}
			
			.modem-info-box .ifacebox-head,
			.modem-info-box .ifacebox-body {
				user-select: none;
				-webkit-user-select: none;
				-moz-user-select: none;
				-ms-user-select: none;
				cursor: default;
			}
			
			.modem-name-truncate {
				white-space: nowrap;
				overflow: hidden;
				text-overflow: ellipsis;
				max-width: 100%;
				display: block;
			}
		`;
		document.head.appendChild(style);
	},

	getCurrentSmsCount: function(comm_port, storage) {
		if (!comm_port) return Promise.resolve(0);
		
		let storageType = storage || 'MS';
		
		return L.resolveDefault(
			fs.exec(smsToolBin(), ['-s', storageType, '-d', comm_port, 'status']),
			null
		).then(function(res) {
			if (!res || res.code !== 0) return 0;
			
			try {
				let output = res.stdout || '';
				let stx = output.substring(22, 27);
				let smsCount = parseInt(stx.replace(/[^0-9]/g, '')) || 0;
				return smsCount;
			} catch(e) {
				return 0;
			}
		});
	},

	getModemData: function(comm_port, forced_plmn_op, mbim_op, modemdata) {
		let script = '';
		let args = [];
		
		if (modemdata === 'serial' || modemdata === 'ecm') {
			script = '/usr/bin/md_serial_ecm';
			args = [comm_port, '', forced_plmn_op];
		} else if (modemdata === 'uqmi') {
			script = '/usr/bin/md_uqmi';
			args = [comm_port, '', forced_plmn_op, mbim_op];
		} else if (modemdata === 'mm') {
			script = '/usr/bin/md_modemmanager';
			args = [comm_port, '', forced_plmn_op];
		} else {
			return Promise.resolve(null);
		}
		
		return L.resolveDefault(fs.exec_direct(script, args), null).then(function(res) {
			if (!res) return null;
			
			try {
				let jsonraw = JSON.parse(res.replace(/[\u0000-\u001F\u007F-\u009F]/g, ""));
				let json = Object.values(jsonraw);
				
				if (!json || json.length < 3 || !json[0] || !json[1] || !json[2]) {
					return null;
				}
				
				let signalQuality = 0;
				if (json[2].csq_per) {
					signalQuality = parseInt(json[2].csq_per) || 0;
				} else if (json[2].csq) {
					let csq = parseInt(json[2].csq);
					if (!isNaN(csq) && csq >= 0) {
						signalQuality = Math.min(Math.round((csq / 31) * 100), 100);
					}
				}
				
				return {
					operator: json[2].operator_name || '-',
					mode: json[2].mode || '-',
					signalQuality: signalQuality
				};
			} catch(e) {
				return null;
			}
		});
	},

	getSignalIcon: function(quality) {
		let icon;
		if (quality <= 0)
			icon = L.resource('icons/5gmodem/mobile-signal-000-000.svg');
		else if (quality < 20)
			icon = L.resource('icons/5gmodem/mobile-signal-000-020.svg');
		else if (quality < 40)
			icon = L.resource('icons/5gmodem/mobile-signal-020-040.svg');
		else if (quality < 60)
			icon = L.resource('icons/5gmodem/mobile-signal-040-060.svg');
		else if (quality < 80)
			icon = L.resource('icons/5gmodem/mobile-signal-060-080.svg');
		else
			icon = L.resource('icons/5gmodem/mobile-signal-080-100.svg');
		return icon;
	},

	formatMode: function(modeRaw) {
		if (!modeRaw || modeRaw.length <= 1 || modeRaw === '-') {
			return '-';
		}
		
		let modeUp = modeRaw.toUpperCase();
		let modeDisplay;
		
		if (modeUp.indexOf('LTE') >= 0 || modeUp.indexOf('5G') >= 0) {
			let tech = '';
			if (modeUp.indexOf('LTE') >= 0) {
				tech = modeRaw.split(' ')[0];
			}
			if (modeUp.indexOf('5G') >= 0) {
				tech = modeRaw.split(' ')[0];
				if (modeRaw.split(' ')[1]) {
					tech += ' ' + modeRaw.split(' ')[1];
				}
			}
			
			let count = (modeRaw.match(/\//g) || []).length + 1;
			modeDisplay = (count > 1) ? (tech + ' (' + count + 'CA)') : tech;
		} else {
			modeDisplay = modeRaw.split(' ')[0];
		}
		
		modeDisplay = modeDisplay.replace('LTE_A', 'LTE-A');
		return modeDisplay;
	},

	renderModemBadge: function(modemData, hasFullData, onHeaderClick) {
		let operator = modemData.operator || '-';
		let technology = this.formatMode(modemData.mode);
		let modemName = modemData.modemName || 'Modem';
		let smsCount = modemData.smsCount || 0;
		let signalQuality = modemData.signalQuality || 0;

		let truncatedName = modemName;
		if (modemName.length > 25) {
			truncatedName = modemName.substring(0, 22) + '...';
		}
		
		let signalIcon = this.getSignalIcon(signalQuality);
		let smsIconUrl = L.resource('icons/5gmodem/newdelsms.png');
		
		if (!hasFullData) {
			return E('div', { 
				'class': 'ifacebox modem-info-box',
				'style': 'margin:0.2em;flex:1;min-width:80px;max-width:100px;'
			}, [
				E('div', { 
					'class': 'ifacebox-head port-label',
					'style': 'padding:4px 6px;font-weight:normal;font-size:13px;cursor:pointer;',
					'click': onHeaderClick
				}, [
					E('span', { 'class': 'modem-name-truncate' }, _('SMS Info'))
				]),
				E('div', { 
					'class': 'ifacebox-body',
					'style': 'padding:8px;text-align:center;display:block;'
				}, [
					E('span', {
						'title': smsCount > 0 ? '%s: %d'.format(_('New SMS'), smsCount) : _('No new SMS'),
						'style': 'position:relative;display:inline-block;' + (smsCount === 0 ? 'opacity:1;' : ''),
						'class': smsCount > 0 ? 'sms-icon-active' : ''
					}, [
						E('img', { 
							'src': smsIconUrl,
							'style': 'width:28px;height:28px;'
						}),
						smsCount > 0 ? E('span', {
							'class': 'modem-sms-badge'
						}, String(smsCount)) : ''
					])
				])
			]);
		}
		
		return E('div', { 
			'class': 'ifacebox modem-info-box',
			'style': 'margin:0.2em;flex:1;min-width:160px;max-width:220px;'
		}, [
			E('div', { 
				'class': 'ifacebox-head port-label',
				'style': 'padding:4px 6px;font-weight:normal;font-size:13px;cursor:pointer;',
				'click': onHeaderClick
			}, [
				E('span', { 'class': 'modem-name-truncate', 'title': modemName }, truncatedName)
			]),
			E('div', { 
				'class': 'ifacebox-body',
				'style': 'padding:4px 6px;display:block;'
			}, [
				E('table', {
					'style': 'width:100%;border:none;border-collapse:collapse;table-layout:fixed;margin:0;'
				}, [
					E('tr', {}, [
						E('td', {
							'style': 'width:66%;border:none;padding:2px;vertical-align:middle;text-align:center;'
						}, [
							E('span', {
								'title': '%s: %d%%'.format(_('Signal Quality'), signalQuality),
								'style': 'display:inline-block;'
							}, [
								E('img', { 
									'src': signalIcon,
									'style': 'width:28px;height:28px;vertical-align:middle;'
								}),
								E('span', { 'style': 'vertical-align:middle;font-size:12px;' }, [
									' ',
									operator,
									E('br'),
									E('small', { 'style': 'font-size:10px;' }, technology)
								])
							])
						]),
						E('td', {
							'style': 'width:34%;border:none;border-left:1px solid var(--border-color-medium);padding:2px;text-align:center;vertical-align:middle;'
						}, [
							E('span', {
								'title': smsCount > 0 ? '%s: %d'.format(_('New SMS'), smsCount) : _('No new SMS'),
								'style': 'position:relative;display:inline-block;',
								'class': smsCount > 0 ? 'sms-icon-with-messages' : 'sms-icon-no-messages'
							}, [
								E('img', { 
									'src': smsIconUrl,
									'style': 'width:28px;height:28px;'
								}),
								smsCount > 0 ? E('span', {
									'class': 'modem-sms-badge'
								}, String(smsCount)) : ''
							])
						])
					])
				])
			])
		]);
	},

	parseSmsCountUniversal: function(smsCountString, modemIndex) {
		if (!smsCountString) return 0;

		let parts = smsCountString.split(' ').filter(function(p) { return p.trim() !== ''; });

		let dfmParts = {};
		let hasDfmFormat = false;
		for (let i = 0; i < parts.length; i++) {
			let match = parts[i].match(/^dfm(\d+)_(\d+)$/);
			if (match) {
				hasDfmFormat = true;
				dfmParts[parseInt(match[1])] = parseInt(match[2]) || 0;
			}
		}

		if (hasDfmFormat) {
			if (modemIndex != null) {
				return dfmParts[modemIndex] || 0;
			} else {
				if (dfmParts[1] != null) {
					return dfmParts[1];
				}
				let keys = Object.keys(dfmParts);
				if (keys.length > 0) {
					return dfmParts[parseInt(keys[0])] || 0;
				}
				return 0;
			}
		}

		let simpleMatch = smsCountString.match(/^(\d+)(\s|$)/);
		if (simpleMatch) {
			return parseInt(simpleMatch[1]) || 0;
		}

		return 0;
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('defmodems'))
		]).then(L.bind(function() {
			let onTopSms = uci.get('5gmodem', 'sms', 'ontopsms');

			if (onTopSms !== '1') {
				return null;
			}

			window.modemDetectorCounter = ('modemDetectorCounter' in window) ?
				++window.modemDetectorCounter : 0;

			if (!('modemDetectorData' in window)) {
				window.modemDetectorData = null;
			}

			if (window.modemDetectorData !== null &&
			    window.modemDetectorCounter % this.checkInterval !== 0) {
				return window.modemDetectorData;
			}

			window.modemDetectorCache = {};

			let defmodemSections = uci.sections('defmodems', 'defmodems') || [];
			let smsCountString = uci.get('5gmodem', 'sms', 'sms_count') || '';
			let storage = uci.get('5gmodem', 'sms', 'storage') || 'MS';
			let readport = uci.get('5gmodem', 'sms', 'readport') || '/dev/ttyUSB2';

			let serialModems = defmodemSections.filter(function(s) {
				return s.modemdata === 'serial';
			}).slice(0, 5);

			let hasDefmodems = serialModems.length > 0;

			if (hasDefmodems) {
				let modemsToLoad = [];
				for (let i = 0; i < serialModems.length; i++) {
					let modem = serialModems[i];
					modemsToLoad.push({
						index: i + 1,
						comm_port: modem.comm_port || '',
						forced_plmn_op: modem.forced_plmn_op || '0',
						mbim_op: modem.mbim_op || '0',
						modemdata: modem.modemdata || 'serial',
						modemName: modem.modem || (_('Modem') + ' ' + (i + 1)),
						smsCount: this.parseSmsCountUniversal(smsCountString, i + 1),
						storage: storage,
						skipModemData: false
					});
				}
				window.modemDetectorData = {
					modems: modemsToLoad,
					mode: 'multi'
				};
				return window.modemDetectorData;
			}

			let savedSmsCount = this.parseSmsCountUniversal(smsCountString, null);

			window.modemDetectorData = {
				modems: [{
					index: 1,
					comm_port: readport,
					forced_plmn_op: '0',
					mbim_op: '0',
					modemdata: 'serial',
					modemName: 'Modem',
					smsCount: savedSmsCount,
					storage: storage,
					skipModemData: false
				}],
				mode: 'sms-only'
			};
			return window.modemDetectorData;

		}, this));
	},

	render: function(data) {
		this.addStyles();
		
		if (!data || !data.modems || data.modems.length === 0) {
			return null;
		}
		
		let currentAlignment = this.restoreAlignmentSettings();
		let alignmentStyle = this.getAlignmentStyle(currentAlignment);
		
		let container = E('div', { 
			'class': 'network-status-table',
			'style': 'display:flex;flex-wrap:wrap;gap:6px;' + alignmentStyle
		});
		
		let hasDefmodems = data.mode === 'multi';
		let isSmsOnly = data.mode === 'sms-only';
		
		let self = this;
		let onHeaderClick = function(ev) {
			ev.stopPropagation();
			self.showAlignmentModal(container);
		};
		
		data.modems.forEach(L.bind(function(modem) {
			let badgeId = 'modem-badge-' + modem.index;
			let skipModemData = modem.skipModemData || isSmsOnly;
			
			if (window.modemDetectorCache && window.modemDetectorCache[modem.index]) {
				let cached = window.modemDetectorCache[modem.index];
				container.appendChild(this.renderModemBadge(cached, hasDefmodems && !skipModemData, onHeaderClick));
			} else {
				let boxStyle = skipModemData
					? 'margin:0.2em;flex:1;min-width:80px;max-width:100px;'
					: 'margin:0.2em;flex:1;min-width:160px;max-width:220px;';

				container.appendChild(
					E('div', {
						'class': 'ifacebox modem-info-box',
						'style': boxStyle,
						'id': badgeId
					}, [
						E('div', {
							'class': 'ifacebox-head port-label',
							'style': 'padding:4px 6px;font-weight:normal;font-size:13px;cursor:pointer;',
							'click': onHeaderClick
						}, [
							E('span', { 'class': 'modem-name-truncate', 'title': modem.modemName || _('Modem') },
								modem.modemName || (_('Modem') + ': ' + modem.index))
						]),
						E('div', {
							'class': 'ifacebox-body',
							'style': 'padding:8px;text-align:center;display:flex;align-items:center;justify-content:center;gap:6px;'
						}, [
							E('span', {'class': 'spinning', 'style': 'display:inline-block;'}),
							E('span', {'style': 'font-size:12px;'}, _('Loading...'))
						])
					])
				);

				let modemDataPromise = skipModemData
					? Promise.resolve(null)
					: this.getModemData(modem.comm_port, modem.forced_plmn_op, modem.mbim_op, modem.modemdata);

				let sleepPromise = new Promise(function(resolve) { setTimeout(resolve, 2000); });

				Promise.all([
					modemDataPromise,
					this.getCurrentSmsCount(modem.comm_port, modem.storage),
					sleepPromise
				]).then(L.bind(function(results) {
					let result = results[0];
					let currentSmsCount = results[1];

					let savedSmsCount = modem.smsCount || 0;
					let newSmsCount = Math.max(0, currentSmsCount - savedSmsCount);

					let modemInfo = {
						operator: '-',
						mode: '-',
						modemName: modem.modemName || _('Modem'),
						smsCount: newSmsCount,
						signalQuality: 0
					};

					if (result) {
						modemInfo.operator = result.operator || '-';
						modemInfo.mode = result.mode || '-';
						modemInfo.signalQuality = result.signalQuality || 0;
					}

					if (!window.modemDetectorCache) {
						window.modemDetectorCache = {};
					}
					window.modemDetectorCache[modem.index] = modemInfo;

					let badgeElement = document.getElementById(badgeId);
					if (badgeElement) {
						let newBadge = this.renderModemBadge(modemInfo, hasDefmodems && !skipModemData, onHeaderClick);
						newBadge.id = badgeId;
						badgeElement.parentNode.replaceChild(newBadge, badgeElement);
					}
				}, this));
			}
		}, this));
		
		return container;
	}
});
