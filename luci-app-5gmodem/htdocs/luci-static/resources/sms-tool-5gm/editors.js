'use strict';
'require baseclass';
'require fs';
'require ui';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.

	Shared editor/manager dialogs (user contacts, USSD code files, AT
	command files), extracted from smsconfig.js so that the Send/USSD/AT
	tabs can open them too.
*/

function popTimeout(a, message, timeout, severity) {
    ui.addTimeLimitedNotification(a, message, timeout, severity);
}

function getDateTimeSuffix() {
	let now = new Date();
	let pad = function(n) { return String(n).padStart(2, '0'); };
	return now.getFullYear() + '-' +
		   pad(now.getMonth() + 1) + '-' +
		   pad(now.getDate()) + '_' +
		   pad(now.getHours()) + '-' +
		   pad(now.getMinutes()) + '-' +
		   pad(now.getSeconds());
}

let phonebookEditorDialog = baseclass.extend({
	__init__: function(title, content) {
		this.title = title;
		this.content = content || '';
	},

	render: function() {
		let self = this;

		ui.showModal(this.title, [
			E('textarea', {
				'id': 'phonebook_modal_editor',
				'class': 'cbi-input-textarea',
				'style': 'width:100% !important; height:50vh; min-height:300px;',
				'wrap': 'off',
				'spellcheck': 'false'
			}, this.content.trim()),
			E('p', {'style': 'margin-top: 10px; font-size: 12px; color: var(--text-color-secondary)'}),

			E('div', {'style': 'display: flex; justify-content: space-between; align-items: center; margin-top: 10px;'}, [
				E('div', {}, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, _('Close'))
				]),
				E('div', {'style': 'display: flex; gap: 10px; align-items: center;'}, [
					(function() {
						var comboBtn = new ui.ComboButton('_load_user', {
							'_load_user': _('Load .user file'),
							'_save_user': _('Save .user file')
						}, {
							'click': function(ev, name) {
								if (name === '_load_user') {
									let input = document.createElement('input');
									input.type = 'file';
									input.accept = '.user';
									input.onchange = function(e) {
										let file = e.target.files[0];
										if (!file) return;
										let reader = new FileReader();
										reader.onload = function(event) {
											let content = event.target.result;
											let targetPath = '/etc/5gmodem/modem/phonebook.user';
											fs.write(targetPath, content)
												.then(function() {
													popTimeout(null, E('p', {}, _('File uploaded and saved to') + ' ' + targetPath), 5000, 'info');
													return fs.read(targetPath);
												})
												.then(function(savedContent) {
													let textarea = document.getElementById('phonebook_modal_editor');
													if (textarea) {
														textarea.value = savedContent;
													}
												})
												.catch(function(e) {
													ui.addNotification(null, E('p', {}, _('Unable to upload file') + ': ' + e.message), 'error');
												});
										};
										reader.readAsText(file);
									};
									input.click();
								} else if (name === '_save_user') {
									let textarea = document.getElementById('phonebook_modal_editor');
									let content = textarea ? textarea.value : '';
									let blob = new Blob([content], { type: 'text/plain' });
									let link = document.createElement('a');
									link.download = 'phonebook_' + getDateTimeSuffix() + '.user';
									link.href = URL.createObjectURL(blob);
									link.click();
									URL.revokeObjectURL(link.href);
								}
							},
							'classes': {
								'_load_user': 'cbi-button cbi-button-action important',
								'_save_user': 'cbi-button cbi-button-neutral'
							}
						});
						return comboBtn.render();
					})(),
					E('button', {
						'class': 'btn cbi-button-save',
						'click': ui.createHandlerFn(this, function() {
							let textarea = document.getElementById('phonebook_modal_editor');
							let newContent = textarea.value.trim().replace(/\r\n/g, '\n') + '\n';
							
							fs.write('/etc/5gmodem/modem/phonebook.user', newContent)
								.then(function() {
									popTimeout(null, E('p', {}, _('Phonebook saved successfully')), 5000, 'info');
									ui.hideModal();
								})
								.catch(function(e) {
									ui.addNotification(null, E('p', {}, _('Unable to save the file') + ': ' + e.message), 'error');
								});
						})
					}, _('Save'))
				])
			])
		], 'cbi-modal');
	},

	show: function() {
		this.render();
	}
});

let ussdCodesManagerDialog = baseclass.extend({
	__init__: function(title) {
		this.title = title;
		this.baseDir = '/etc/5gmodem/modem/ussdcodes';
		this.fallbackFile = '/etc/5gmodem/modem/ussdcodes.user';
		this.currentFile = null;
	},

	loadFileList: function() {
		return fs.exec('/bin/sh', ['-c', 'ls ' + this.baseDir + '/*.user 2>/dev/null || true'])
			.then(function(res) {
				let files = (res.stdout || '').trim().split('\n').filter(f => f);
				let fileNames = files.map(f => f.replace(this.baseDir + '/', ''));
				fileNames.sort();
				return fileNames;
			}.bind(this))
			.catch(function() {
				return [];
			});
	},

	loadInitialContent: function() {
		let self = this;
		return this.loadFileList().then(function(files) {
			if (files.length > 0) {
				self.currentFile = files[0];
				return fs.read(self.baseDir + '/' + files[0])
					.then(function(content) {
						return { files: files, content: content || '', selectedFile: files[0] };
					})
					.catch(function() {
						return { files: files, content: '', selectedFile: files[0] };
					});
			} else {
				return fs.read(self.fallbackFile)
					.then(function(content) {
						return { files: [], content: content || '', selectedFile: '' };
					})
					.catch(function() {
						return { files: [], content: '', selectedFile: '' };
					});
			}
		});
	},

	render: function() {
		let self = this;

		this.loadInitialContent().then(function(data) {
			ui.showModal(self.title, [
				E('div', {'class': 'cbi-section'}, [
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('Select file')),
						E('div', {'class': 'cbi-value-field'}, [
							E('select', {
								'class': 'cbi-input-select',
								'id': 'ussd_file_select',
								'style': 'width: 100%;',
								'change': function() {
									let fileName = this.value;
									if (fileName) {
										self.currentFile = fileName;
										self.loadFileContent(fileName);
									}
								}
							}, [
								E('option', {'value': ''}, _('-- Select file --'))
							].concat(data.files.map(f => E('option', {'value': f}, f))))
						])
					]),
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('New file name')),
						E('div', {'class': 'cbi-value-field'}, [
							E('div', {'style': 'display: flex; gap: 10px;'}, [
								E('input', {
									'class': 'cbi-input-text',
									'id': 'ussd_new_filename',
									'type': 'text',
									'placeholder': _('filename.user'),
									'style': 'flex: 1;'
								}),
								E('button', {
									'class': 'btn cbi-button-add',
									'click': ui.createHandlerFn(self, self.createNewFile)
								}, _('Create'))
							])
						])
					]),
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('Deleting files')),
						E('div', {'class': 'cbi-value-field'}, [
							(function() {
								var delCombo = new ui.ComboButton('_delete_selected', {
									'_delete_selected': _('Delete selected file'),
									'_delete_all':      _('Delete all files')
								}, {
									'click': function(ev, name) {
										if (name === '_delete_selected') {
											self.deleteFile();
										} else if (name === '_delete_all') {
											self.deleteAllFiles();
										}
									},
									'classes': {
										'_delete_selected': 'cbi-button cbi-button-remove',
										'_delete_all':      'cbi-button cbi-button-remove'
									}
								});
								return delCombo.render();
							})()
						])
					])
				]),
				E('textarea', {
					'id': 'ussd_modal_editor',
					'class': 'cbi-input-textarea',
					'style': 'width:100% !important; height:40vh; min-height:250px; margin-top: 10px;',
					'wrap': 'off',
					'spellcheck': 'false',
					'placeholder': _('Select or create a file to edit...')
				}, data.content),

				E('div', {'style': 'display: flex; justify-content: space-between; align-items: center; margin-top: 10px;'}, [
					E('div', {}, [
						E('button', {
							'class': 'btn',
							'click': ui.hideModal
						}, _('Close'))
					]),
					E('div', {'style': 'display: flex; gap: 10px; align-items: center;'}, [
						(function() {
							var comboBtn = new ui.ComboButton('_load_user', {
								'_load_user':    _('Load .user file'),
								'_save_user':    _('Save .user file'),
								'_load_gz':      _('Load .gz archive'),
								'_save_gz':      _('Save .gz archive')
							}, {
								'click': function(ev, name) {
									if (name === '_load_user') {
										let input = document.createElement('input');
										input.type = 'file';
										input.accept = '.user';
										input.onchange = function(e) {
											let file = e.target.files[0];
											if (!file) return;
											let reader = new FileReader();
											reader.onload = function(event) {
												let content = event.target.result;
												let fileName = file.name;
												let targetPath = self.baseDir + '/' + fileName;
												fs.write(targetPath, content)
													.then(function() {
														popTimeout(null, E('p', {}, _('File uploaded and saved to') + ' ' + targetPath), 5000, 'info');
														self.currentFile = fileName;
														return self.loadFileList();
													})
													.then(function(files) {
														let select = document.getElementById('ussd_file_select');
														if (select) {
															while (select.options.length > 1) select.remove(1);
															files.forEach(function(f) {
																let opt = document.createElement('option');
																opt.value = f;
																opt.text = f;
																if (f === fileName) opt.selected = true;
																select.appendChild(opt);
															});
														}
														return fs.read(targetPath);
													})
													.then(function(savedContent) {
														let textarea = document.getElementById('ussd_modal_editor');
														if (textarea) textarea.value = savedContent;
													})
													.catch(function(e) {
														ui.addNotification(null, E('p', {}, _('Unable to upload file') + ': ' + e.message), 'error');
													});
											};
											reader.readAsText(file);
										};
										input.click();
									} else if (name === '_save_user') {
										let textarea = document.getElementById('ussd_modal_editor');
										let content = textarea ? textarea.value : '';
										let baseName = (self.currentFile || 'ussdcodes.user').replace(/\.user$/, '');
										let fileName = baseName + '_' + getDateTimeSuffix() + '.user';
										let blob = new Blob([content], { type: 'text/plain' });
										let link = document.createElement('a');
										link.download = fileName;
										link.href = URL.createObjectURL(blob);
										link.click();
										URL.revokeObjectURL(link.href);
									} else if (name === '_load_gz') {
										let tmpPath = '/tmp/ussdcodes_upload.tar.gz';
										ui.uploadFile(tmpPath).then(function() {
												return fs.exec('/bin/tar', ['-xzf', tmpPath, '-C', self.baseDir]);
											}).then(function(res) {
												if (res.code !== 0) {
													ui.addNotification(null, E('p', {}, _('Failed to extract archive') + ': ' + (res.stderr || '')), 'error');
													return;
												}
												return fs.remove(tmpPath).then(function() {
													popTimeout(null, E('p', {}, _('Archive extracted to') + ' ' + self.baseDir), 5000, 'info');
													return self.loadFileList();
												}).then(function(files) {
													let select = document.getElementById('ussd_file_select');
													if (select) {
														while (select.options.length > 1) select.remove(1);
														files.forEach(function(f) {
															let opt = document.createElement('option');
															opt.value = f;
															opt.text = f;
															select.appendChild(opt);
														});
													}
												});
											}).catch(function(e) {
												ui.addNotification(null, E('p', {}, _('Upload error') + ': ' + e.message), 'error');
											});
									} else if (name === '_save_gz') {
										let tmpGz = '/tmp/ussdcodes.tar.gz';
										fs.exec('/bin/tar', ['-czf', tmpGz, '-C', self.baseDir, '.'])
											.then(function(res) {
												if (res.code !== 0) {
													ui.addNotification(null, E('p', {}, _('Failed to create archive') + ': ' + (res.stderr || '')), 'error');
													return;
												}
												return L.resolveDefault(fs.read_direct(tmpGz, 'blob'), null).then(function(blob) {
													if (blob) {
														let link = document.createElement('a');
														link.download = 'ussdcodes_' + getDateTimeSuffix() + '.tar.gz';
														link.href = URL.createObjectURL(blob);
														link.click();
														URL.revokeObjectURL(link.href);
													} else {
														ui.addNotification(null, E('p', {}, _('Failed to read archive')), 'error');
													}
													return fs.remove(tmpGz);
												});
											}).catch(function(e) {
												ui.addNotification(null, E('p', {}, _('Error') + ': ' + e.message), 'error');
											});
									}
								},
								'classes': {
									'_load_user': 'cbi-button cbi-button-action important',
									'_save_user': 'cbi-button cbi-button-neutral',
									'_load_gz':   'cbi-button cbi-button-action important',
									'_save_gz':   'cbi-button cbi-button-neutral'
								}
							});
							return comboBtn.render();
						})(),
						E('button', {
							'class': 'btn cbi-button-save',
							'id': 'ussd_save_btn',
							'click': ui.createHandlerFn(self, self.saveFile)
						}, _('Save'))
					])
				])
			], 'cbi-modal');
			
			setTimeout(function() {
				let select = document.getElementById('ussd_file_select');
				if (select && data.selectedFile) {
					select.value = data.selectedFile;
				}
			}, 0);
		});
	},

	loadFileContent: function(fileName) {
		let filePath = this.baseDir + '/' + fileName;
		fs.read(filePath)
			.then(function(content) {
				let textarea = document.getElementById('ussd_modal_editor');
				if (textarea) {
					textarea.value = content || '';
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to load file') + ': ' + e.message), 'error');
			});
	},

	createNewFile: function() {
		let input = document.getElementById('ussd_new_filename');
		let fileName = input.value.trim();

		if (!fileName) {
			ui.addNotification(null, E('p', {}, _('Please enter a file name')), 'warning');
			return;
		}

		if (!fileName.endsWith('.user')) {
			fileName += '.user';
		}

		let filePath = this.baseDir + '/' + fileName;

		fs.exec('/bin/sh', ['-c', 'mkdir -p ' + this.baseDir])
			.then(function() {
				return fs.write(filePath, '');
			}.bind(this))
			.then(function() {
				return fs.exec('/bin/chmod', ['644', filePath]);
			})
			.then(function() {
				popTimeout(null, E('p', {}, _('File created successfully')), 5000, 'info');
				this.currentFile = fileName;
				input.value = '';
				
				let select = document.getElementById('ussd_file_select');
				let option = E('option', {'value': fileName, 'selected': 'selected'}, fileName);
				select.appendChild(option);
				select.value = fileName;
				
				let textarea = document.getElementById('ussd_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = '';
				}
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to create file') + ': ' + e.message), 'error');
			});
	},

	deleteFile: function() {
		let select = document.getElementById('ussd_file_select');
		let fileName = select.value;

		if (!fileName) {
			ui.addNotification(null, E('p', {}, _('Please select a file to delete')), 'warning');
			return;
		}

		if (!confirm(_('Are you sure you want to delete this file?') + '\n' + fileName)) {
			return;
		}

		let filePath = this.baseDir + '/' + fileName;

		fs.exec('/bin/rm', ['-f', filePath])
			.then(function() {
				popTimeout(null, E('p', {}, _('File deleted successfully')), 5000, 'info');
				
				let option = select.querySelector('option[value="' + fileName + '"]');
				if (option) {
					option.remove();
				}
				select.value = '';
				this.currentFile = null;
				
				let textarea = document.getElementById('ussd_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = _('Select or create a file to edit...');
				}
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to delete file') + ': ' + e.message), 'error');
			});
	},

	deleteAllFiles: function() {
		if (!confirm(_('Are you sure you want to delete all files in the folder?') + '\n' + this.baseDir)) {
			return;
		}

		let self = this;
		fs.exec('/bin/sh', ['-c', 'rm -f ' + this.baseDir + '/*.user'])
			.then(function() {
				popTimeout(null, E('p', {}, _('All files deleted successfully')), 5000, 'info');

				let select = document.getElementById('ussd_file_select');
				if (select) {
					while (select.options.length > 1) select.remove(1);
					select.value = '';
				}
				self.currentFile = null;

				let textarea = document.getElementById('ussd_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = _('Select or create a file to edit...');
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to delete files') + ': ' + e.message), 'error');
			});
	},

	saveFile: function() {
		if (!this.currentFile) {
			ui.addNotification(null, E('p', {}, _('Please select or create a file first')), 'warning');
			return;
		}

		let textarea = document.getElementById('ussd_modal_editor');
		let content = textarea.value.trim().replace(/\r\n/g, '\n') + '\n';
		let filePath = this.baseDir + '/' + this.currentFile;

		fs.write(filePath, content)
			.then(function() {
				popTimeout(null, E('p', {}, _('File saved successfully')), 5000, 'info');
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to save file') + ': ' + e.message), 'error');
			});
	},

	show: function() {
		this.render();
	}
});

let atCommandsManagerDialog = baseclass.extend({
	__init__: function(title) {
		this.title = title;
		this.baseDir = '/etc/5gmodem/modem/atcmmds';
		this.fallbackFile = '/etc/5gmodem/modem/atcmmds.user';
		this.currentFile = null;
	},

	loadFileList: function() {
		return fs.exec('/bin/sh', ['-c', 'ls ' + this.baseDir + '/*.user 2>/dev/null || true'])
			.then(function(res) {
				let files = (res.stdout || '').trim().split('\n').filter(f => f);
				let fileNames = files.map(f => f.replace(this.baseDir + '/', ''));
				fileNames.sort();
				return fileNames;
			}.bind(this))
			.catch(function() {
				return [];
			});
	},

	loadInitialContent: function() {
		let self = this;
		return this.loadFileList().then(function(files) {
			if (files.length > 0) {
				self.currentFile = files[0];
				return fs.read(self.baseDir + '/' + files[0])
					.then(function(content) {
						return { files: files, content: content || '', selectedFile: files[0] };
					})
					.catch(function() {
						return { files: files, content: '', selectedFile: files[0] };
					});
			} else {
				return fs.read(self.fallbackFile)
					.then(function(content) {
						return { files: [], content: content || '', selectedFile: '' };
					})
					.catch(function() {
						return { files: [], content: '', selectedFile: '' };
					});
			}
		});
	},

	render: function() {
		let self = this;

		this.loadInitialContent().then(function(data) {
			ui.showModal(self.title, [
				E('div', {'class': 'cbi-section'}, [
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('Select file')),
						E('div', {'class': 'cbi-value-field'}, [
							E('select', {
								'class': 'cbi-input-select',
								'id': 'at_file_select',
								'style': 'width: 100%;',
								'change': function() {
									let fileName = this.value;
									if (fileName) {
										self.currentFile = fileName;
										self.loadFileContent(fileName);
									}
								}
							}, [
								E('option', {'value': ''}, _('-- Select file --'))
							].concat(data.files.map(f => E('option', {'value': f}, f))))
						])
					]),
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('New file name')),
						E('div', {'class': 'cbi-value-field'}, [
							E('div', {'style': 'display: flex; gap: 10px;'}, [
								E('input', {
									'class': 'cbi-input-text',
									'id': 'at_new_filename',
									'type': 'text',
									'placeholder': _('filename.user'),
									'style': 'flex: 1;'
								}),
								E('button', {
									'class': 'btn cbi-button-add',
									'click': ui.createHandlerFn(self, self.createNewFile)
								}, _('Create'))
							])
						])
					]),
					E('div', {'class': 'cbi-value'}, [
						E('label', {'class': 'cbi-value-title'}, _('Deleting files')),
						E('div', {'class': 'cbi-value-field'}, [
							(function() {
								var delCombo = new ui.ComboButton('_delete_selected', {
									'_delete_selected': _('Delete selected file'),
									'_delete_all':      _('Delete all files')
								}, {
									'click': function(ev, name) {
										if (name === '_delete_selected') {
											self.deleteFile();
										} else if (name === '_delete_all') {
											self.deleteAllFiles();
										}
									},
									'classes': {
										'_delete_selected': 'cbi-button cbi-button-remove',
										'_delete_all':      'cbi-button cbi-button-remove'
									}
								});
								return delCombo.render();
							})()
						])
					])
				]),
				E('textarea', {
					'id': 'at_modal_editor',
					'class': 'cbi-input-textarea',
					'style': 'width:100% !important; height:40vh; min-height:250px; margin-top: 10px;',
					'wrap': 'off',
					'spellcheck': 'false',
					'placeholder': _('Select or create a file to edit...')
				}, data.content),

				E('div', {'style': 'display: flex; justify-content: space-between; align-items: center; margin-top: 10px;'}, [
					E('div', {}, [
						E('button', {
							'class': 'btn',
							'click': ui.hideModal
						}, _('Close'))
					]),
					E('div', {'style': 'display: flex; gap: 10px; align-items: center;'}, [
						(function() {
							var comboBtn = new ui.ComboButton('_load_user', {
								'_load_user':    _('Load .user file'),
								'_save_user':    _('Save .user file'),
								'_load_gz':      _('Load .gz archive'),
								'_save_gz':      _('Save .gz archive')
							}, {
								'click': function(ev, name) {
									if (name === '_load_user') {
										let input = document.createElement('input');
										input.type = 'file';
										input.accept = '.user';
										input.onchange = function(e) {
											let file = e.target.files[0];
											if (!file) return;
											let reader = new FileReader();
											reader.onload = function(event) {
												let content = event.target.result;
												let fileName = file.name;
												let targetPath = self.baseDir + '/' + fileName;
												fs.write(targetPath, content)
													.then(function() {
														popTimeout(null, E('p', {}, _('File uploaded and saved to') + ' ' + targetPath), 5000, 'info');
														self.currentFile = fileName;
														return self.loadFileList();
													})
													.then(function(files) {
														let select = document.getElementById('at_file_select');
														if (select) {
															while (select.options.length > 1) select.remove(1);
															files.forEach(function(f) {
																let opt = document.createElement('option');
																opt.value = f;
																opt.text = f;
																if (f === fileName) opt.selected = true;
																select.appendChild(opt);
															});
														}
														return fs.read(targetPath);
													})
													.then(function(savedContent) {
														let textarea = document.getElementById('at_modal_editor');
														if (textarea) textarea.value = savedContent;
													})
													.catch(function(e) {
														ui.addNotification(null, E('p', {}, _('Unable to upload file') + ': ' + e.message), 'error');
													});
											};
											reader.readAsText(file);
										};
										input.click();
									} else if (name === '_save_user') {
										let textarea = document.getElementById('at_modal_editor');
										let content = textarea ? textarea.value : '';
										let baseName = (self.currentFile || 'atcmmds.user').replace(/\.user$/, '');
										let fileName = baseName + '_' + getDateTimeSuffix() + '.user';
										let blob = new Blob([content], { type: 'text/plain' });
										let link = document.createElement('a');
										link.download = fileName;
										link.href = URL.createObjectURL(blob);
										link.click();
										URL.revokeObjectURL(link.href);
									} else if (name === '_load_gz') {
										let tmpPath = '/tmp/atcmmds_upload.tar.gz';
										ui.uploadFile(tmpPath).then(function() {
												return fs.exec('/bin/tar', ['-xzf', tmpPath, '-C', self.baseDir]);
											}).then(function(res) {
												if (res.code !== 0) {
													ui.addNotification(null, E('p', {}, _('Failed to extract archive') + ': ' + (res.stderr || '')), 'error');
													return;
												}
												return fs.remove(tmpPath).then(function() {
													popTimeout(null, E('p', {}, _('Archive extracted to') + ' ' + self.baseDir), 5000, 'info');
													return self.loadFileList();
												}).then(function(files) {
													let select = document.getElementById('at_file_select');
													if (select) {
														while (select.options.length > 1) select.remove(1);
														files.forEach(function(f) {
															let opt = document.createElement('option');
															opt.value = f;
															opt.text = f;
															select.appendChild(opt);
														});
													}
												});
											}).catch(function(e) {
												ui.addNotification(null, E('p', {}, _('Upload error') + ': ' + e.message), 'error');
											});
									} else if (name === '_save_gz') {
										let tmpGz = '/tmp/atcmmds.tar.gz';
										fs.exec('/bin/tar', ['-czf', tmpGz, '-C', self.baseDir, '.'])
											.then(function(res) {
												if (res.code !== 0) {
													ui.addNotification(null, E('p', {}, _('Failed to create archive') + ': ' + (res.stderr || '')), 'error');
													return;
												}
												return L.resolveDefault(fs.read_direct(tmpGz, 'blob'), null).then(function(blob) {
													if (blob) {
														let link = document.createElement('a');
														link.download = 'atcmmds_' + getDateTimeSuffix() + '.tar.gz';
														link.href = URL.createObjectURL(blob);
														link.click();
														URL.revokeObjectURL(link.href);
													} else {
														ui.addNotification(null, E('p', {}, _('Failed to read archive')), 'error');
													}
													return fs.remove(tmpGz);
												});
											}).catch(function(e) {
												ui.addNotification(null, E('p', {}, _('Error') + ': ' + e.message), 'error');
											});
									}
								},
								'classes': {
									'_load_user': 'cbi-button cbi-button-action important',
									'_save_user': 'cbi-button cbi-button-neutral',
									'_load_gz':   'cbi-button cbi-button-action important',
									'_save_gz':   'cbi-button cbi-button-neutral'
								}
							});
							return comboBtn.render();
						})(),
						E('button', {
							'class': 'btn cbi-button-save',
							'id': 'at_save_btn',
							'click': ui.createHandlerFn(self, self.saveFile)
						}, _('Save'))
					])
				])
			], 'cbi-modal');
			
			setTimeout(function() {
				let select = document.getElementById('at_file_select');
				if (select && data.selectedFile) {
					select.value = data.selectedFile;
				}
			}, 0);
		});
	},

	loadFileContent: function(fileName) {
		let filePath = this.baseDir + '/' + fileName;
		fs.read(filePath)
			.then(function(content) {
				let textarea = document.getElementById('at_modal_editor');
				if (textarea) {
					textarea.value = content || '';
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to load file') + ': ' + e.message), 'error');
			});
	},

	createNewFile: function() {
		let input = document.getElementById('at_new_filename');
		let fileName = input.value.trim();

		if (!fileName) {
			ui.addNotification(null, E('p', {}, _('Please enter a file name')), 'warning');
			return;
		}

		if (!fileName.endsWith('.user')) {
			fileName += '.user';
		}

		let filePath = this.baseDir + '/' + fileName;

		fs.exec('/bin/sh', ['-c', 'mkdir -p ' + this.baseDir])
			.then(function() {
				return fs.write(filePath, '');
			}.bind(this))
			.then(function() {
				return fs.exec('/bin/chmod', ['644', filePath]);
			})
			.then(function() {
				popTimeout(null, E('p', {}, _('File created successfully')), 5000, 'info');
				this.currentFile = fileName;
				input.value = '';
				
				let select = document.getElementById('at_file_select');
				let option = E('option', {'value': fileName, 'selected': 'selected'}, fileName);
				select.appendChild(option);
				select.value = fileName;
				
				let textarea = document.getElementById('at_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = '';
				}
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to create file') + ': ' + e.message), 'error');
			});
	},

	deleteFile: function() {
		let select = document.getElementById('at_file_select');
		let fileName = select.value;

		if (!fileName) {
			ui.addNotification(null, E('p', {}, _('Please select a file to delete')), 'warning');
			return;
		}

		if (!confirm(_('Are you sure you want to delete this file?') + '\n' + fileName)) {
			return;
		}

		let filePath = this.baseDir + '/' + fileName;

		fs.exec('/bin/rm', ['-f', filePath])
			.then(function() {
				popTimeout(null, E('p', {}, _('File deleted successfully')), 5000, 'info');
				
				let option = select.querySelector('option[value="' + fileName + '"]');
				if (option) {
					option.remove();
				}
				select.value = '';
				this.currentFile = null;
				
				let textarea = document.getElementById('at_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = _('Select or create a file to edit...');
				}
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to delete file') + ': ' + e.message), 'error');
			});
	},

	deleteAllFiles: function() {
		if (!confirm(_('Are you sure you want to delete all files in the folder?') + '\n' + this.baseDir)) {
			return;
		}

		let self = this;
		fs.exec('/bin/sh', ['-c', 'rm -f ' + this.baseDir + '/*.user'])
			.then(function() {
				popTimeout(null, E('p', {}, _('All files deleted successfully')), 5000, 'info');

				let select = document.getElementById('at_file_select');
				if (select) {
					while (select.options.length > 1) select.remove(1);
					select.value = '';
				}
				self.currentFile = null;

				let textarea = document.getElementById('at_modal_editor');
				if (textarea) {
					textarea.value = '';
					textarea.placeholder = _('Select or create a file to edit...');
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to delete files') + ': ' + e.message), 'error');
			});
	},

	saveFile: function() {
		if (!this.currentFile) {
			ui.addNotification(null, E('p', {}, _('Please select or create a file first')), 'warning');
			return;
		}

		let textarea = document.getElementById('at_modal_editor');
		let content = textarea.value.trim().replace(/\r\n/g, '\n') + '\n';
		let filePath = this.baseDir + '/' + this.currentFile;

		fs.write(filePath, content)
			.then(function() {
				popTimeout(null, E('p', {}, _('File saved successfully')), 5000, 'info');
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, _('Unable to save file') + ': ' + e.message), 'error');
			});
	},

	show: function() {
		this.render();
	}
});

return baseclass.extend({
	phonebookEditorDialog: phonebookEditorDialog,
	ussdCodesManagerDialog: ussdCodesManagerDialog,
	atCommandsManagerDialog: atCommandsManagerDialog
});
