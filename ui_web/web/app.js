const state = {
  clients: [],
  tasks: [],
  passwordItems: [],
  links: [],
  selectedClient: "",
  selectedTask: "",
  clientForm: { extraLinks: [] },
  builderId: "user_term",
  currentScript: "",
};

const apiWarningMethods = new Set();

function pyApi() {
  return window.pywebview && window.pywebview.api;
}

function isApiMethodReady(method) {
  const api = pyApi();
  return Boolean(api && typeof api[method] === "function");
}

async function callApi(method, ...args) {
  const api = pyApi();
  if (!api || typeof api[method] !== "function") {
    setStatus(`PyWebView API is not ready for ${method}.`);
    if (!apiWarningMethods.has(method)) {
      apiWarningMethods.add(method);
      appendLog(`WARN PyWebView API is not ready. Run app.py through the desktop launcher.`);
    }
    return {};
  }
  try {
    return await api[method](...args);
  } catch (error) {
    setStatus(String(error));
    appendLog(`ERROR ${error}`);
    return { ok: false, error: String(error), status: String(error) };
  }
}

function $(selector) {
  return document.querySelector(selector);
}

function $all(selector) {
  return Array.from(document.querySelectorAll(selector));
}

function normalize(value) {
  return String(value || "").trim().toLowerCase();
}

function rankedMatches(options, value) {
  const query = normalize(value);
  if (!query) {
    return [...options];
  }

  const starts = [];
  const contains = [];
  options.forEach((option) => {
    const normalized = normalize(option);
    if (normalized.startsWith(query)) {
      starts.push(option);
    } else if (normalized.includes(query)) {
      contains.push(option);
    }
  });
  return [...starts, ...contains];
}

function slugify(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

function setStatus(message) {
  if (message) {
    $("#status-text").textContent = message;
  }
}

function appendLog(line) {
  if (!line) {
    return;
  }
  const output = $("#log-output");
  if (!output) {
    return;
  }
  const stamped = /^\d{2}:\d{2}:\d{2}/.test(line)
    ? line
    : `${new Date().toLocaleTimeString()} ${line}`;
  const existingLines = output.textContent ? output.textContent.split("\n") : [];
  const lastLine = existingLines[existingLines.length - 1] || "";
  const messageWithoutTime = stamped.replace(/^\d{1,2}:\d{2}:\d{2}\s?(AM|PM)?\s+/i, "");
  const lastWithoutTime = lastLine.replace(/^\d{1,2}:\d{2}:\d{2}\s?(AM|PM)?\s+/i, "");

  if (messageWithoutTime === lastWithoutTime) {
    return;
  }

  const nextLines = [...existingLines, stamped].slice(-250);
  output.textContent = nextLines.join("\n");
  output.scrollTop = output.scrollHeight;
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function highlightPowerShell(script) {
  return String(script || "")
    .split("\n")
    .map((line) => {
      if (line.trim().startsWith("#")) {
        return `<span class="ps-comment">${escapeHtml(line)}</span>`;
      }

      let html = escapeHtml(line);
      html = html.replace(/(&quot;.*?&quot;|&#039;.*?&#039;)/g, '<span class="ps-string">$1</span>');
      html = html.replace(/(\$[A-Za-z_][A-Za-z0-9_]*)/g, '<span class="ps-variable">$1</span>');
      html = html.replace(
        /\b(function|param|begin|process|end|if|elseif|else|foreach|for|while|switch|try|catch|finally|return|throw|Import-Module|Connect-MgGraph|Connect-ExchangeOnline|Get-Mailbox|Set-Mailbox|Enable-Mailbox|Disable-Mailbox|Get-MailboxPermission|Add-MailboxPermission|Remove-MailboxPermission|Get-RecipientPermission|Add-RecipientPermission|Remove-RecipientPermission|Get-InboxRule|Disable-InboxRule|Set-ADUser|New-ADUser|Enable-ADAccount|Disable-ADAccount|Move-ADObject|Update-MgUser|Get-ADUser|Get-ADGroup|Add-ADGroupMember|Remove-ADGroupMember|Set-ADAccountPassword|Unlock-ADAccount|Start-ADSyncSyncCycle|Invoke-MgGraphRequest)\b/g,
        '<span class="ps-keyword">$1</span>',
      );
      return html;
    })
    .join("\n");
}

function setPreview(script) {
  $("#command-preview").innerHTML = highlightPowerShell(script || "# Generated script preview will appear here.");
}

class PreservedAutocomplete {
  constructor(root, getOptions, onCommit) {
    this.root = root;
    this.input = root.querySelector("input");
    this.popup = root.querySelector(".suggestions");
    this.getOptions = getOptions;
    this.onCommit = onCommit;
    this.matches = [];
    this.activeIndex = 0;

    this.input.addEventListener("focus", () => this.showAll());
    this.input.addEventListener("click", () => this.showAll());
    this.input.addEventListener("input", () => this.showFiltered());
    this.input.addEventListener("blur", () => {
      window.setTimeout(() => {
        this.acceptFirstMatch();
        this.close();
      }, 80);
    });
    this.input.addEventListener("keydown", (event) => this.handleKeydown(event));
  }

  setValue(value, fireCommit = false) {
    this.input.value = value || "";
    if (fireCommit) {
      this.onCommit(this.input.value);
    }
  }

  showAll() {
    this.matches = [...this.getOptions()];
    this.activeIndex = 0;
    this.render();
  }

  showFiltered() {
    this.matches = rankedMatches(this.getOptions(), this.input.value);
    this.activeIndex = 0;
    this.render();
  }

  render() {
    this.popup.innerHTML = "";
    if (!this.matches.length) {
      this.close();
      return;
    }

    this.matches.slice(0, 45).forEach((match, index) => {
      const row = document.createElement("div");
      row.className = `suggestion${index === this.activeIndex ? " is-active" : ""}`;
      row.textContent = match;
      row.setAttribute("role", "option");
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        this.commit(match);
      });
      this.popup.appendChild(row);
    });
    this.popup.classList.add("is-open");
  }

  close() {
    this.popup.classList.remove("is-open");
  }

  commit(value) {
    this.input.value = value || "";
    this.close();
    this.onCommit(this.input.value);
  }

  acceptFirstMatch() {
    const text = this.input.value.trim();
    if (!text) {
      return false;
    }
    const match = rankedMatches(this.getOptions(), text)[0];
    if (!match) {
      return false;
    }
    if (this.input.value !== match) {
      this.input.value = match;
      this.onCommit(match);
    }
    return true;
  }

  handleKeydown(event) {
    if (event.key === "Tab") {
      this.acceptFirstMatch();
      return;
    }
    if (event.key === "Escape") {
      this.close();
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (!this.matches.length) {
        this.showFiltered();
        return;
      }
      this.activeIndex = Math.min(this.activeIndex + 1, this.matches.length - 1);
      this.render();
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      this.activeIndex = Math.max(this.activeIndex - 1, 0);
      this.render();
      return;
    }
    if (event.key === "Enter" && this.matches.length) {
      event.preventDefault();
      this.commit(this.matches[this.activeIndex] || this.matches[0]);
    }
  }
}

const customSelects = new Map();

class CustomSelect {
  constructor(select) {
    this.select = select;
    this.options = [];
    this.activeIndex = 0;

    this.root = document.createElement("div");
    this.root.className = "custom-select";
    this.button = document.createElement("button");
    this.button.type = "button";
    this.button.className = "custom-select-button";
    this.button.setAttribute("aria-haspopup", "listbox");
    this.button.setAttribute("aria-expanded", "false");
    this.menu = document.createElement("div");
    this.menu.className = "suggestions custom-select-menu";
    this.menu.setAttribute("role", "listbox");

    this.root.append(this.button, this.menu);
    this.select.classList.add("native-select-source");
    this.select.tabIndex = -1;
    this.select.insertAdjacentElement("afterend", this.root);

    this.button.addEventListener("click", () => this.toggle());
    this.button.addEventListener("keydown", (event) => this.handleKeydown(event));
    this.root.addEventListener("focusout", () => {
      window.setTimeout(() => {
        if (!this.root.contains(document.activeElement)) {
          this.close();
        }
      }, 0);
    });
    document.addEventListener("mousedown", (event) => {
      if (!this.root.contains(event.target)) {
        this.close();
      }
    });
    this.select.addEventListener("change", () => this.render());
    this.render();
  }

  render(preserveActive = false) {
    this.options = Array.from(this.select.options);
    const selectedIndex = Math.max(0, this.select.selectedIndex);
    if (!preserveActive) {
      this.activeIndex = Math.min(selectedIndex, Math.max(0, this.options.length - 1));
    }
    const selected = this.options[selectedIndex];
    this.button.textContent = selected ? selected.textContent : "";
    this.menu.innerHTML = "";

    this.options.forEach((option, index) => {
      const row = document.createElement("div");
      row.className = `suggestion${index === this.activeIndex ? " is-active" : ""}${option.selected ? " is-selected" : ""}`;
      row.textContent = option.textContent;
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", option.selected ? "true" : "false");
      if (option.disabled) {
        row.classList.add("is-disabled");
      }
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        if (!option.disabled) {
          this.commit(index);
        }
      });
      this.menu.appendChild(row);
    });
  }

  open() {
    closeCustomSelects(this);
    this.render();
    this.root.classList.add("is-open");
    this.menu.classList.add("is-open");
    this.button.setAttribute("aria-expanded", "true");
  }

  close() {
    this.root.classList.remove("is-open");
    this.menu.classList.remove("is-open");
    this.button.setAttribute("aria-expanded", "false");
  }

  toggle() {
    if (this.root.classList.contains("is-open")) {
      this.close();
      return;
    }
    this.open();
  }

  commit(index) {
    const option = this.options[index];
    if (!option || option.disabled) {
      return;
    }
    this.select.value = option.value;
    this.render();
    this.close();
    this.select.dispatchEvent(new Event("change", { bubbles: true }));
  }

  move(delta) {
    if (!this.options.length) {
      return;
    }
    let nextIndex = this.activeIndex;
    for (let step = 0; step < this.options.length; step += 1) {
      nextIndex = Math.max(0, Math.min(nextIndex + delta, this.options.length - 1));
      if (!this.options[nextIndex].disabled) {
        this.activeIndex = nextIndex;
        this.render(true);
        const active = this.menu.children[this.activeIndex];
        if (active) {
          active.scrollIntoView({ block: "nearest" });
        }
        return;
      }
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.close();
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (!this.root.classList.contains("is-open")) {
        this.open();
        return;
      }
      this.move(1);
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      if (!this.root.classList.contains("is-open")) {
        this.open();
        return;
      }
      this.move(-1);
      return;
    }
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      if (!this.root.classList.contains("is-open")) {
        this.open();
        return;
      }
      this.commit(this.activeIndex);
    }
  }
}

function closeCustomSelects(except = null) {
  customSelects.forEach((customSelect) => {
    if (customSelect !== except) {
      customSelect.close();
    }
  });
}

function setupCustomSelects(scope = document) {
  scope.querySelectorAll("select").forEach((select) => {
    if (customSelects.has(select)) {
      customSelects.get(select).render();
      return;
    }
    customSelects.set(select, new CustomSelect(select));
  });
}

function syncCustomSelect(select) {
  const customSelect = customSelects.get(select);
  if (customSelect) {
    customSelect.render();
  }
}

function setSelectValue(select, value) {
  select.value = value || "";
  syncCustomSelect(select);
}

let clientAutocomplete;
let taskAutocomplete;
let clientFormAutocomplete;
let termClientAutocomplete;
let newClientAutocomplete;
let lockdownClientAutocomplete;
let chromeInitialized = false;
let backendInitialized = false;
let backendLoadInProgress = false;

function setupNavigation() {
  $all("[data-view-button]").forEach((button) => {
    button.addEventListener("click", () => showView(button.dataset.viewButton));
  });

  window.addEventListener("keydown", (event) => {
    if (event.altKey && event.key.toLowerCase() === "c") {
      event.preventDefault();
      showView("launcher");
      $("#client-input").focus();
      $("#client-input").select();
    }
  });
}

function showView(target) {
  $all("[data-view-button]").forEach((item) => item.classList.toggle("is-active", item.dataset.viewButton === target));
  $all("[data-view]").forEach((view) => view.classList.toggle("is-active", view.dataset.view === target));
}

function setupTabs() {
  $all("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      const tab = button.dataset.tab;
      $all("[data-tab]").forEach((item) => item.classList.toggle("is-active", item === button));
      $all("[data-tab-panel]").forEach((panel) => panel.classList.toggle("is-active", panel.dataset.tabPanel === tab));
    });
  });
}

function setupCheckboxKeyboard(scope = document) {
  scope.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
    if (checkbox.dataset.enterBound === "true") {
      return;
    }
    checkbox.dataset.enterBound = "true";
    checkbox.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        checkbox.checked = !checkbox.checked;
        checkbox.dispatchEvent(new Event("change", { bubbles: true }));
      }
    });
  });
}

function applyLauncherPayload(payload) {
  const launcher = payload || {};
  renderPasswords(launcher.passwordItems || []);
  renderLinks(launcher.links || []);
  if (launcher.passwordHeading) {
    $("#password-heading").textContent = launcher.passwordHeading;
  }
}

function renderPasswords(items) {
  state.passwordItems = items || [];
  const list = $("#password-list");
  list.innerHTML = "";
  if (!state.passwordItems.length) {
    const empty = document.createElement("p");
    empty.className = "hint";
    empty.textContent = "No passwords or extra links configured for this client.";
    list.appendChild(empty);
    updatePasswordHeading();
    updateLaunchButtons();
    return;
  }

  state.passwordItems.forEach((item, index) => {
    const label = document.createElement("label");
    label.className = "check-row";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = Boolean(item.selected);
    checkbox.dataset.label = item.label;
    checkbox.dataset.key = item.key;
    checkbox.id = `password-item-${index}`;
    checkbox.addEventListener("change", () => {
      updatePasswordHeading();
      updateLaunchButtons();
    });
    label.appendChild(checkbox);
    label.append(document.createTextNode(item.label));
    list.appendChild(label);
  });
  setupCheckboxKeyboard(list);
  updatePasswordHeading();
  updateLaunchButtons();
}

function selectedPasswordKeys() {
  return $all("#password-list input:checked").map((checkbox) => checkbox.dataset.key);
}

function updatePasswordHeading() {
  const total = state.passwordItems.length;
  const selected = selectedPasswordKeys().length;
  $("#password-heading").textContent = state.selectedClient
    ? `${state.selectedClient} Passwords and extra links (${selected}/${total} selected):`
    : "Client Passwords and extra links:";
}

function updateLaunchButtons() {
  $("#launch-selected").disabled = selectedPasswordKeys().length === 0;
  $("#launch-all").disabled = selectedPasswordKeys().length === 0 && state.links.filter((link) => link.valid).length === 0;
}

function renderLinks(links) {
  state.links = links || [];
  const tbody = $("#links-body");
  tbody.innerHTML = "";
  if (!state.links.length) {
    const row = document.createElement("tr");
    row.innerHTML = '<td colspan="3" class="hint">Select a task to show constructed links.</td>';
    tbody.appendChild(row);
    updateLaunchButtons();
    return;
  }

  state.links.forEach((link) => {
    const row = document.createElement("tr");
    row.tabIndex = link.valid ? 0 : -1;
    row.className = link.valid ? "ready-row" : "broken-row";
    if (link.valid) {
      row.setAttribute("role", "button");
      row.setAttribute("title", "Double-click or press Enter to open this link.");
    }
    const status = link.valid ? "Ready" : "Blocked";
    row.innerHTML = `
      <td>${escapeHtml(link.label)}</td>
      <td>${escapeHtml(link.url)}</td>
      <td><span class="status-pill${link.valid ? "" : " missing"}">${status}</span></td>
    `;
    row.addEventListener("dblclick", () => {
      if (link.valid) {
        openConstructedLink(link.url);
      }
    });
    row.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && link.valid) {
        openConstructedLink(link.url);
      }
    });
    tbody.appendChild(row);
  });
  updateLaunchButtons();
}

async function openConstructedLink(url) {
  const response = await callApi("open_link", url);
  handleResponse(response);
}

function renderClientForm(form) {
  state.clientForm = { ...(form || {}), extraLinks: (form && form.extraLinks) || [] };
  if (clientFormAutocomplete) {
    clientFormAutocomplete.setValue(state.clientForm.name || "");
  } else {
    $("#client-form-name").value = state.clientForm.name || "";
  }
  $("#client-form-id").textContent = state.clientForm.id || "";
  $("#client-form-slug").textContent = state.clientForm.slug || "";
  $("#client-form-itglue-org").value = state.clientForm.itglueOrgId || "";
  $("#client-form-user-create-term").value = state.clientForm.userCreateTermUrl || "";
  $("#client-form-outage").value = state.clientForm.outageHandlingUrl || "";
  $("#client-form-primary-admin").value = state.clientForm.primaryAdminPasswordId || "";
  $("#client-form-office365").value = state.clientForm.office365PasswordId || "";
  $("#client-form-localadmin").value = state.clientForm.localAdminPasswordId || "";
  $("#client-form-duo").value = state.clientForm.duoPasswordId || "";
  $("#client-form-screenconnect").value = state.clientForm.screenconnectUrl || "";
  fillSelect($("#client-form-sop"), state.clientForm.sopOptions || [], state.clientForm.newUserSopKey || "");
  fillSelect($("#extra-task"), state.clientForm.taskOptions || [], "Not tied to a task");
  renderExtraLinks();
}

function fillSelect(select, values, selected) {
  select.innerHTML = "";
  values.forEach((value) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    option.selected = value === selected;
    select.appendChild(option);
  });
  syncCustomSelect(select);
}

function renderExtraLinks() {
  const tbody = $("#extra-links-body");
  tbody.innerHTML = "";
  state.clientForm.extraLinks.forEach((item, index) => {
    const row = document.createElement("tr");
    row.innerHTML = `
      <td><input type="radio" name="extra-link-selection" value="${index}"></td>
      <td>${escapeHtml(item.label)}</td>
      <td>${escapeHtml(item.taskName || "Not tied to a task")}</td>
      <td>${escapeHtml(item.value)}</td>
    `;
    tbody.appendChild(row);
  });
}

function collectClientPayload() {
  return {
    loadedId: state.clientForm.loadedId || "",
    name: $("#client-form-name").value,
    itglueOrgId: $("#client-form-itglue-org").value,
    userCreateTermUrl: $("#client-form-user-create-term").value,
    outageHandlingUrl: $("#client-form-outage").value,
    primaryAdminPasswordId: $("#client-form-primary-admin").value,
    office365PasswordId: $("#client-form-office365").value,
    localAdminPasswordId: $("#client-form-localadmin").value,
    duoPasswordId: $("#client-form-duo").value,
    newUserSopKey: $("#client-form-sop").value,
    screenconnectUrl: $("#client-form-screenconnect").value,
    extraLinks: state.clientForm.extraLinks || [],
  };
}

function setupClientForm() {
  $("#client-form-name").addEventListener("input", () => {
    const slug = slugify($("#client-form-name").value);
    $("#client-form-id").textContent = slug;
    $("#client-form-slug").textContent = slug;
  });

  $("#save-client").addEventListener("click", async () => {
    const response = await callApi("save_client", collectClientPayload());
    handleResponse(response);
    if (response.clients) {
      state.clients = response.clients;
    }
    if (response.selectedClient) {
      state.selectedClient = response.selectedClient;
      clientAutocomplete.setValue(response.selectedClient);
    }
    if (response.launcher) {
      applyLauncherPayload(response.launcher);
    }
    if (response.clientForm) {
      renderClientForm(response.clientForm);
    }
    if (response.builder) {
      renderBuilder(response.builder);
    }
  });

  $("#clear-client-form").addEventListener("click", () => {
    renderClientForm({ name: "", id: "", slug: "", extraLinks: [], sopOptions: state.clientForm.sopOptions || [], taskOptions: state.clientForm.taskOptions || [] });
    setStatus("Form cleared.");
  });

  $("#add-extra").addEventListener("click", () => {
    const label = $("#extra-label").value.trim();
    const value = $("#extra-value").value.trim();
    const taskName = $("#extra-task").value || "Not tied to a task";
    if (!label || !value) {
      setStatus("Extra field requires both label and value.");
      return;
    }
    const existingIndex = state.clientForm.extraLinks.findIndex((item) =>
      normalize(item.label) === normalize(label) && normalize(item.taskName) === normalize(taskName)
    );
    const entry = { label, value, taskName };
    if (existingIndex >= 0) {
      state.clientForm.extraLinks[existingIndex] = entry;
    } else {
      state.clientForm.extraLinks.push(entry);
    }
    $("#extra-label").value = "";
    $("#extra-value").value = "";
    renderExtraLinks();
  });

  $("#remove-extra").addEventListener("click", () => {
    const selected = $('input[name="extra-link-selection"]:checked');
    if (!selected) {
      setStatus("Select an extra field row to remove.");
      return;
    }
    state.clientForm.extraLinks.splice(Number(selected.value), 1);
    renderExtraLinks();
  });
}

function renderBuilder(builder) {
  const payload = builder || {};
  state.builderId = payload.id || state.builderId || "user_term";
  $("#user-term-builder").hidden = state.builderId !== "user_term";
  $("#user-new-builder").hidden = state.builderId !== "user_new";
  $("#user-lockdown-builder").hidden = state.builderId !== "user_lockdown";
  setSelectValue($("#builder-selector"), state.builderId);
  state.currentScript = "";
  setPreview();

  if (state.builderId === "user_new") {
    if (newClientAutocomplete) {
      newClientAutocomplete.setValue(payload.client || state.selectedClient || "");
    } else {
      $("#new-client").value = payload.client || state.selectedClient || "";
    }
    $("#new-first-name").value = payload.firstName || "";
    $("#new-last-name").value = payload.lastName || "";
    $("#new-copy-after").value = payload.copyAfter || "";
    $("#new-sam").value = payload.samAccountName || "";
    $("#new-upn").value = payload.userPrincipalName || "";
    $("#new-target-ou").value = payload.targetOu || "";
    $("#new-title").value = payload.title || "";
    $("#new-department").value = payload.department || "";
    $("#new-description").value = payload.description || "";
    $("#new-manager").value = payload.manager || "";
    $("#new-mapped-drives").value = payload.mappedDrives || "";
    $("#new-run-adsync").checked = Boolean(payload.runAdsync);
    $("#new-must-change").checked = payload.mustChange !== false;
    $("#new-dry-run").checked = payload.dryRun !== false;
    $("#new-force").checked = Boolean(payload.force);
    $("#new-resume-existing").checked = Boolean(payload.resumeExistingUser);
    $("#new-resume-lookup").value = payload.resumeUserLookup || "";
    $("#new-poll-seconds").value = payload.pollSeconds || 5;
    $("#new-poll-attempts").value = payload.pollAttempts || 100;
    return;
  }

  if (state.builderId === "user_lockdown") {
    if (lockdownClientAutocomplete) {
      lockdownClientAutocomplete.setValue(payload.client || state.selectedClient || "");
    } else {
      $("#lockdown-client").value = payload.client || state.selectedClient || "";
    }
    $("#lockdown-user-lookup").value = payload.userLookup || "";
    $("#lockdown-ticket").value = payload.ticket || "";
    $("#lockdown-run-adsync").checked = Boolean(payload.runAdsync);
    $("#lockdown-check-email-rules").checked = payload.checkEmailRules !== false;
    $("#lockdown-dry-run").checked = payload.dryRun !== false;
    $("#lockdown-force").checked = Boolean(payload.force);
    return;
  }

  if (termClientAutocomplete) {
    termClientAutocomplete.setValue(payload.client || state.selectedClient || "");
  } else {
    $("#term-client").value = payload.client || state.selectedClient || "";
  }
  $("#term-disabled-ou").value = payload.disabledOu || "";
  $("#term-user-lookup").value = payload.userLookup || "";
  $("#term-ticket").value = payload.ticket || "";
  $("#term-groups").value = payload.groups || "";
  $("#term-full-access").value = payload.fullAccess || "";
  $("#term-send-as").value = payload.sendAs || "";
  $("#term-send-on-behalf").value = payload.sendOnBehalf || "";
  $("#term-convert-shared").checked = Boolean(payload.convertShared);
  $("#term-hide-gal").checked = Boolean(payload.hideGal);
  $("#term-sent-copy").checked = Boolean(payload.sentCopy);
  $("#term-run-adsync").checked = Boolean(payload.runAdsync);
  $("#term-dry-run").checked = Boolean(payload.dryRun);
  $("#term-force").checked = Boolean(payload.force);
  $("#term-skip-verified").checked = Boolean(payload.skipVerified);
  $("#term-poll-seconds").value = payload.pollSeconds || 10;
  $("#term-poll-attempts").value = payload.pollAttempts || 40;
}

function collectBuilderPayload() {
  if (state.builderId === "user_new") {
    return {
      client: $("#new-client").value,
      firstName: $("#new-first-name").value,
      lastName: $("#new-last-name").value,
      copyAfter: $("#new-copy-after").value,
      samAccountName: $("#new-sam").value,
      userPrincipalName: $("#new-upn").value,
      targetOu: $("#new-target-ou").value,
      title: $("#new-title").value,
      department: $("#new-department").value,
      description: $("#new-description").value,
      manager: $("#new-manager").value,
      mappedDrives: $("#new-mapped-drives").value,
      runAdsync: $("#new-run-adsync").checked,
      mustChange: $("#new-must-change").checked,
      dryRun: $("#new-dry-run").checked,
      force: $("#new-force").checked,
      resumeExistingUser: $("#new-resume-existing").checked,
      resumeUserLookup: $("#new-resume-lookup").value,
      pollSeconds: Number($("#new-poll-seconds").value || 5),
      pollAttempts: Number($("#new-poll-attempts").value || 100),
    };
  }
  if (state.builderId === "user_lockdown") {
    return {
      client: $("#lockdown-client").value,
      userLookup: $("#lockdown-user-lookup").value,
      ticket: $("#lockdown-ticket").value,
      runAdsync: $("#lockdown-run-adsync").checked,
      checkEmailRules: $("#lockdown-check-email-rules").checked,
      dryRun: $("#lockdown-dry-run").checked,
      force: $("#lockdown-force").checked,
    };
  }
  return {
    client: $("#term-client").value,
    disabledOu: $("#term-disabled-ou").value,
    userLookup: $("#term-user-lookup").value,
    ticket: $("#term-ticket").value,
    groups: $("#term-groups").value,
    fullAccess: $("#term-full-access").value,
    sendAs: $("#term-send-as").value,
    sendOnBehalf: $("#term-send-on-behalf").value,
    convertShared: $("#term-convert-shared").checked,
    hideGal: $("#term-hide-gal").checked,
    sentCopy: $("#term-sent-copy").checked,
    runAdsync: $("#term-run-adsync").checked,
    dryRun: $("#term-dry-run").checked,
    force: $("#term-force").checked,
    skipVerified: $("#term-skip-verified").checked,
    pollSeconds: Number($("#term-poll-seconds").value || 10),
    pollAttempts: Number($("#term-poll-attempts").value || 40),
  };
}

function setupBuilderActions() {
  $("#builder-selector").addEventListener("change", async () => {
    const response = await callApi("builder_context", $("#builder-selector").value, state.selectedClient);
    if (response.builder) {
      renderBuilder(response.builder);
    }
  });

  $("#generate-preview").addEventListener("click", async () => {
    try {
      const response = await callApi("generate_script", state.builderId, collectBuilderPayload());
      handleResponse(response);
      if (response.script) {
        state.currentScript = response.script;
        setPreview(response.script);
      }
    } catch (error) {
      setStatus(`Could not generate preview: ${error.message || error}`);
    }
  });

  $("#copy-script").addEventListener("click", async () => {
    try {
      if (!state.currentScript) {
        const response = await callApi("generate_script", state.builderId, collectBuilderPayload());
        handleResponse(response);
        if (!response.script) {
          return;
        }
        state.currentScript = response.script;
        setPreview(response.script);
      }
      await navigator.clipboard.writeText(state.currentScript);
      setStatus(`${builderLabel()} script copied to clipboard.`);
    } catch (error) {
      setStatus(`Could not copy script: ${error.message || error}`);
    }
  });

  $("#save-script").addEventListener("click", async () => {
    try {
      const response = await callApi("save_script", state.builderId, collectBuilderPayload());
      handleResponse(response);
    } catch (error) {
      setStatus(`Could not save script: ${error.message || error}`);
    }
  });

  $("#open-template").addEventListener("click", async () => {
    try {
      const response = await callApi("open_template", state.builderId);
      handleResponse(response);
    } catch (error) {
      setStatus(`Could not open template: ${error.message || error}`);
    }
  });
}

function builderLabel() {
  if (state.builderId === "user_new") {
    return "User New";
  }
  if (state.builderId === "user_lockdown") {
    return "User Lockdown";
  }
  return "User Term";
}

function setupLauncherActions() {
  $("#select-all").addEventListener("click", () => {
    $all("#password-list input").forEach((checkbox) => {
      checkbox.checked = true;
    });
    updatePasswordHeading();
    updateLaunchButtons();
  });

  $("#clear-all").addEventListener("click", () => {
    $all("#password-list input").forEach((checkbox) => {
      checkbox.checked = false;
    });
    updatePasswordHeading();
    updateLaunchButtons();
  });

  $("#launch-all").addEventListener("click", async () => {
    const response = await callApi("launch_all", state.selectedClient, state.selectedTask, selectedPasswordKeys());
    handleResponse(response);
    if (response.openBuilder) {
      await openScriptBuilder(response.openBuilder, { focusFirstField: true });
    }
  });

  $("#launch-selected").addEventListener("click", async () => {
    const response = await callApi("launch_selected", state.selectedClient, selectedPasswordKeys());
    handleResponse(response);
  });

  $("#open-config").addEventListener("click", openConfig);
  $("#settings-open-config").addEventListener("click", openConfig);
}

function focusBuilderField(builderId) {
  const selector = {
    user_new: "#new-client",
    user_lockdown: "#lockdown-client",
    user_term: "#term-client",
  }[builderId] || "#term-client";
  const field = $(selector);
  if (!field) {
    return;
  }
  field.focus();
  if (typeof field.select === "function") {
    field.select();
  }
}

async function focusAppAndBuilderField(builderId) {
  await callApi("focus_window");
  [40, 180, 420, 800].forEach((delay) => {
    window.setTimeout(() => {
      focusBuilderField(builderId);
      callApi("focus_window");
    }, delay);
  });
}

async function openScriptBuilder(builderId, options = {}) {
  showView("script-builders");
  const response = await callApi("builder_context", builderId, state.selectedClient);
  if (response.builder) {
    renderBuilder(response.builder);
  }
  if (options.focusFirstField) {
    await focusAppAndBuilderField(builderId);
  }
}

async function openConfig() {
  const response = await callApi("open_config");
  handleResponse(response);
}

async function onClientCommitted(clientName) {
  state.selectedClient = clientName;
  const response = await callApi("select_client", clientName, state.selectedTask);
  applySelectionResponse(response);
}

async function onTaskCommitted(taskName) {
  state.selectedTask = taskName;
  const response = await callApi("select_task", state.selectedClient, taskName);
  applySelectionResponse(response);
  if (response.openBuilder) {
    const builderResponse = await callApi("builder_context", response.openBuilder, state.selectedClient);
    if (builderResponse.builder) {
      renderBuilder(builderResponse.builder);
    }
  }
}

async function onClientFormCommitted(clientName) {
  state.selectedClient = clientName;
  const response = await callApi("select_client", clientName, state.selectedTask);
  applySelectionResponse(response);
}

async function onTermClientCommitted(clientName) {
  const response = await callApi("builder_context", "user_term", clientName);
  if (response.builder) {
    renderBuilder(response.builder);
  }
}

async function onNewClientCommitted(clientName) {
  const response = await callApi("builder_context", "user_new", clientName);
  if (response.builder) {
    renderBuilder(response.builder);
  }
}

async function onLockdownClientCommitted(clientName) {
  const response = await callApi("builder_context", "user_lockdown", clientName);
  if (response.builder) {
    renderBuilder(response.builder);
  }
}

function applyInitialState(initial, { logInitialMessages = true } = {}) {
  if (!initial || !initial.clients) {
    return false;
  }

  state.clients = initial.clients || [];
  state.tasks = initial.tasks || [];
  state.selectedClient = initial.selectedClient || "";
  state.selectedTask = initial.selectedTask || "";

  clientAutocomplete.setValue(state.selectedClient);
  taskAutocomplete.setValue(state.selectedTask);
  fillSelect(
    $("#builder-selector"),
    (initial.scriptBuilders || []).map((builder) => builder.id),
    "user_term",
  );
  $all("#builder-selector option").forEach((option) => {
    const match = (initial.scriptBuilders || []).find((builder) => builder.id === option.value);
    if (match) {
      option.textContent = match.label;
    }
  });
  syncCustomSelect($("#builder-selector"));

  document.body.dataset.theme = initial.theme || "command";
  document.body.dataset.uiStyle = initial.style || "standard";
  setSelectValue($("#theme-choice"), document.body.dataset.theme);
  setSelectValue($("#style-choice"), document.body.dataset.uiStyle);
  renderHotkey(initial.hotkey || {});
  applyLauncherPayload(initial.launcher || {});
  renderClientForm(initial.clientForm || {});
  renderBuilder(initial.builder || {});
  setStatus(initial.status || "Select a client. Task is optional.");
  if (logInitialMessages) {
    (initial.log || []).forEach(appendLog);
  }
  return true;
}

function applySelectionResponse(response) {
  handleResponse(response);
  if (response.selectedClient !== undefined) {
    state.selectedClient = response.selectedClient;
    clientAutocomplete.setValue(response.selectedClient);
    if (clientFormAutocomplete) {
      clientFormAutocomplete.setValue(response.selectedClient);
    }
  }
  if (response.selectedTask !== undefined) {
    state.selectedTask = response.selectedTask;
    taskAutocomplete.setValue(response.selectedTask);
  }
  if (response.launcher) {
    applyLauncherPayload(response.launcher);
  }
  if (response.clientForm) {
    renderClientForm(response.clientForm);
  }
  if (response.builder) {
    renderBuilder(response.builder);
  }
}

function handleResponse(response) {
  if (!response) {
    return;
  }
  if (response.status) {
    setStatus(response.status);
    appendLog(`${response.ok === false ? "WARN" : "INFO"} ${response.status}`);
  }
  if (response.hotkey) {
    renderHotkey(response.hotkey);
  }
}

function renderHotkey(hotkey) {
  const button = $("#hotkey-button");
  button.textContent = hotkey.text || "Enable hotkey";
  button.disabled = Boolean(hotkey.running);
  button.classList.toggle("is-running", Boolean(hotkey.running));
}

function setupSettings() {
  $("#theme-choice").addEventListener("change", async (event) => {
    document.body.dataset.theme = event.target.value;
    await callApi("set_theme", event.target.value);
  });

  $("#style-choice").addEventListener("change", async (event) => {
    document.body.dataset.uiStyle = event.target.value;
    await callApi("set_style", event.target.value);
  });

  $("#hotkey-button").addEventListener("click", async () => {
    const response = await callApi("enable_hotkey");
    handleResponse(response);
  });
}

function bindChromeOnce() {
  if (chromeInitialized) {
    return;
  }
  chromeInitialized = true;

  setupNavigation();
  setupTabs();
  setupCheckboxKeyboard();
  setupCustomSelects();
  setupLauncherActions();
  setupClientForm();
  setupBuilderActions();
  setupSettings();

  clientAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="client"]'),
    () => state.clients,
    onClientCommitted,
  );
  taskAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="task"]'),
    () => state.tasks,
    onTaskCommitted,
  );
  clientFormAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="client-form"]'),
    () => state.clients,
    onClientFormCommitted,
  );
  termClientAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="term-client"]'),
    () => state.clients,
    onTermClientCommitted,
  );
  newClientAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="new-client"]'),
    () => state.clients,
    onNewClientCommitted,
  );
  lockdownClientAutocomplete = new PreservedAutocomplete(
    $('[data-autocomplete="lockdown-client"]'),
    () => state.clients,
    onLockdownClientCommitted,
  );
}

async function loadBackendState() {
  if (backendInitialized || backendLoadInProgress) {
    return backendInitialized;
  }
  if (!isApiMethodReady("load_initial_state")) {
    setStatus("Waiting for PyWebView bridge.");
    return false;
  }

  backendLoadInProgress = true;
  const initial = await callApi("load_initial_state");
  backendLoadInProgress = false;

  if (!applyInitialState(initial, { logInitialMessages: !backendInitialized })) {
    return false;
  }

  backendInitialized = true;
  return true;
}

function startBackendPolling() {
  let attempts = 0;
  const poll = async () => {
    attempts += 1;
    const loaded = await loadBackendState();
    if (!loaded && attempts < 80) {
      window.setTimeout(poll, 150);
      return;
    }
    if (!loaded) {
      setStatus("PyWebView bridge did not become ready. Restart the app if controls stay inactive.");
      appendLog("WARN PyWebView API is not ready. Run app.py through the desktop launcher.");
    }
  };
  poll();
}

document.addEventListener("pywebviewready", () => {
  bindChromeOnce();
  loadBackendState();
});

document.addEventListener("DOMContentLoaded", () => {
  bindChromeOnce();
  startBackendPolling();
});
