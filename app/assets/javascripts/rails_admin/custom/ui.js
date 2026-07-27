(function ($) {
  "use strict";

  var sidebarPreferenceKey = "infoeducatie.admin.sidebarCollapsed";

  function isDesktopAdmin() {
    return window.matchMedia("(min-width: 992px)").matches;
  }

  function readSidebarPreference() {
    try {
      return window.localStorage.getItem(sidebarPreferenceKey) === "true";
    } catch (_error) {
      return false;
    }
  }

  function writeSidebarPreference(collapsed) {
    try {
      window.localStorage.setItem(sidebarPreferenceKey, String(collapsed));
    } catch (_error) {
      // The shell remains usable when storage is unavailable.
    }
  }

  function updateSidebarToggle(body) {
    var toggle = body.querySelector("[data-admin-sidebar-toggle]");
    if (!toggle) return;

    var expanded = isDesktopAdmin()
      ? !body.classList.contains("ie-sidebar-collapsed")
      : body.classList.contains("ie-sidebar-open");

    toggle.setAttribute("aria-expanded", String(expanded));
    toggle.setAttribute(
      "title",
      expanded ? "Collapse navigation" : "Expand navigation"
    );
  }

  function updateSidebarAccessibility(body) {
    var sidebar = body.querySelector("[data-admin-sidebar]");
    if (!sidebar) return;

    var hidden = !isDesktopAdmin() &&
      !body.classList.contains("ie-sidebar-open");

    if (hidden) {
      sidebar.setAttribute("aria-hidden", "true");
      sidebar.setAttribute("inert", "");
    } else {
      sidebar.removeAttribute("aria-hidden");
      sidebar.removeAttribute("inert");
    }
  }

  function closeMobileSidebar(body, restoreFocus) {
    if (!body.classList.contains("ie-sidebar-open")) return;

    body.classList.remove("ie-sidebar-open");
    updateSidebarToggle(body);
    updateSidebarAccessibility(body);

    if (restoreFocus) {
      var toggle = body.querySelector("[data-admin-sidebar-toggle]");
      if (toggle) toggle.focus();
    }
  }

  function toggleAdminSidebar(body) {
    if (isDesktopAdmin()) {
      var collapsed = body.classList.toggle("ie-sidebar-collapsed");
      writeSidebarPreference(collapsed);
    } else {
      body.classList.toggle("ie-sidebar-open");
    }

    updateSidebarToggle(body);
    updateSidebarAccessibility(body);
  }

  function directLinkForItem(item) {
    var children = item.children;

    for (var index = 0; index < children.length; index += 1) {
      if (children[index].tagName === "A") return children[index];
    }

    return null;
  }

  function filterAdminNavigation(body, query) {
    var navigation = body.querySelector(".ie-admin-sidebar__navigation");
    var list = navigation && navigation.querySelector(".sidebar");
    var clear = body.querySelector("[data-admin-nav-search-clear]");
    var empty = body.querySelector("[data-admin-nav-empty]");
    if (!list) return;

    var normalizedQuery = query.trim().toLocaleLowerCase();
    var items = Array.prototype.slice.call(list.querySelectorAll("li"));
    var leafItems = items.filter(function (item) {
      return directLinkForItem(item) && !item.querySelector("li");
    });

    leafItems.forEach(function (item) {
      var link = directLinkForItem(item);
      var text = link ? link.textContent.trim().toLocaleLowerCase() : "";
      item.hidden = Boolean(normalizedQuery) && text.indexOf(normalizedQuery) === -1;
    });

    Array.prototype.slice.call(list.children).forEach(function (group) {
      var groupLeaves = leafItems.filter(function (item) {
        return group.contains(item);
      });
      var ownLink = directLinkForItem(group);
      var ownText = ownLink ? ownLink.textContent.trim().toLocaleLowerCase() : "";
      var ownMatch = ownText.indexOf(normalizedQuery) !== -1;
      var hasMatch = groupLeaves.some(function (item) {
        return !item.hidden;
      });

      group.hidden = Boolean(normalizedQuery) && !ownMatch && !hasMatch;

      if (normalizedQuery && !group.hidden) {
        Array.prototype.slice.call(group.querySelectorAll(".collapse")).forEach(
          function (collapse) {
            collapse.classList.add("show");
          }
        );
        Array.prototype.slice.call(group.querySelectorAll("[data-bs-toggle='collapse']")).forEach(
          function (trigger) {
            trigger.setAttribute("aria-expanded", "true");
          }
        );
      }
    });

    if (clear) clear.hidden = !normalizedQuery;
    if (empty) {
      empty.hidden = !normalizedQuery ||
        Array.prototype.slice.call(list.children).some(function (group) {
          return !group.hidden;
        });
    }
  }

  function initializeNavigationSearch(body) {
    var input = body.querySelector("[data-admin-nav-search]");
    var clear = body.querySelector("[data-admin-nav-search-clear]");
    if (!input) return;

    input.addEventListener("input", function () {
      filterAdminNavigation(body, input.value);
    });

    if (clear) {
      clear.addEventListener("click", function () {
        input.value = "";
        filterAdminNavigation(body, "");
        input.focus();
      });
    }
  }

  function labelIconActions(body) {
    Array.prototype.slice.call(
      body.querySelectorAll(".nav > li[title] > a, .nav > li > a[title]")
    ).forEach(function (link) {
      var item = link.closest("li");
      var label = link.getAttribute("title") ||
        (item && item.getAttribute("title"));
      if (!label) return;

      if (!link.getAttribute("aria-label")) link.setAttribute("aria-label", label);
      if (!link.getAttribute("title")) link.setAttribute("title", label);
    });
  }

  function initializeAdminShell(scope) {
    var root = scope || document;
    var body = root.matches && root.matches("[data-admin-shell]")
      ? root
      : document.querySelector("[data-admin-shell]");

    if (!body || body.dataset.adminShellReady === "true") return;
    body.dataset.adminShellReady = "true";

    if (isDesktopAdmin() && readSidebarPreference()) {
      body.classList.add("ie-sidebar-collapsed");
    }

    updateSidebarToggle(body);
    updateSidebarAccessibility(body);
    initializeNavigationSearch(body);
    labelIconActions(body);

    var toggle = body.querySelector("[data-admin-sidebar-toggle]");
    if (toggle) {
      toggle.addEventListener("click", function () {
        toggleAdminSidebar(body);
      });
    }

    Array.prototype.slice.call(
      body.querySelectorAll("[data-admin-sidebar-dismiss]")
    ).forEach(function (dismiss) {
      dismiss.addEventListener("click", function () {
        closeMobileSidebar(body, true);
      });
    });

    var sidebar = body.querySelector("[data-admin-sidebar]");
    if (sidebar) {
      sidebar.addEventListener("click", function (event) {
        if (!isDesktopAdmin() && event.target.closest("a")) {
          closeMobileSidebar(body, false);
        }
      });
    }

    body.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeMobileSidebar(body, true);
    });

    window.addEventListener("resize", function () {
      if (!document.body.isSameNode(body)) return;
      if (isDesktopAdmin()) body.classList.remove("ie-sidebar-open");
      updateSidebarToggle(body);
      updateSidebarAccessibility(body);
    });
  }

  function installScreenshotInsertFields() {
    if (!window.nestedFormEvents) return;

    var originalInsertFields = window.nestedFormEvents.insertFields;
    if (originalInsertFields && originalInsertFields.infoeducatieScreenshotAware) {
      return;
    }

    var insertFields = function (content, association, link) {
      var target = $(link).data("target");
      var isScreenshotEditor =
        association === "screenshots" && $(link).data("screenshot-add");

      if (isScreenshotEditor && target) {
        return $(content).appendTo($(target));
      }

      return originalInsertFields.call(window.nestedFormEvents, content, association, link);
    };

    insertFields.infoeducatieScreenshotAware = true;
    window.nestedFormEvents.insertFields = insertFields;
  }

  function refreshScreenshotEditor(editor) {
    var $editor = $(editor);
    var $cards = $editor.find("> [data-screenshot-items] > .fields");
    var activeCards = $cards.not(".is-removed").length;

    $editor.find("> [data-screenshot-empty]").toggle(activeCards === 0);
  }

  function prepareScreenshotCard(field) {
    var $field = $(field);
    var $destroyInput = $field.find("[data-screenshot-destroy]");

    $field.removeClass("tab-pane").addClass("ie-screenshot-editor__item").show();
    $field.toggleClass("is-removed", $destroyInput.val() === "1");
    refreshScreenshotEditor($field.closest("[data-screenshot-editor]"));
  }

  function initializeScreenshotEditors(scope) {
    var $scope = $(scope || document);
    var $editors = $scope.find("[data-screenshot-editor]").add(
      $scope.filter("[data-screenshot-editor]")
    );

    installScreenshotInsertFields();
    $editors.each(function () {
      var $editor = $(this);
      $editor.find("> [data-screenshot-items] > .fields").each(function () {
        prepareScreenshotCard(this);
      });
      refreshScreenshotEditor($editor);
    });
  }

  function setRichTextStatus(editor, message, isError) {
    var status = editor
      .closest("[data-rich-text-editor]")
      .querySelector("[data-rich-text-status]");

    if (!status) return;
    status.textContent = message;
    status.classList.toggle("is-error", Boolean(isError));
  }

  function uploadRichTextImage(editor, attachment) {
    var file = attachment.file;
    var uploadUrl = editor.getAttribute("data-upload-url");
    var csrfToken = document.querySelector('meta[name="csrf-token"]');

    if (!file || !file.type.match(/^image\/(jpeg|png|webp)$/) || !uploadUrl) {
      attachment.remove();
      setRichTextStatus(editor, "Use a JPEG, PNG or WebP image.", true);
      return;
    }

    var body = new FormData();
    body.append("image", file);
    attachment.setUploadProgress(5);
    setRichTextStatus(editor, "Uploading image...", false);

    fetch(uploadUrl, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": csrfToken ? csrfToken.content : ""
      },
      body: body
    })
      .then(function (response) {
        return response.json().then(function (payload) {
          if (!response.ok) throw new Error(payload.error || "Upload failed");
          return payload;
        });
      })
      .then(function (payload) {
        attachment.setAttributes({ url: payload.url, href: payload.url });
        attachment.setUploadProgress(100);
        setRichTextStatus(editor, "Image uploaded.", false);
      })
      .catch(function (error) {
        attachment.remove();
        setRichTextStatus(editor, error.message || "Image upload failed.", true);
      });
  }

  function initializeRichTextEditors(scope) {
    var root = scope || document;
    var editors = Array.prototype.slice.call(
      root.querySelectorAll ? root.querySelectorAll("[data-rich-text-input]") : []
    );

    if (root.matches && root.matches("[data-rich-text-input]")) editors.push(root);

    editors.forEach(function (editor) {
      if (editor.getAttribute("data-rich-text-ready") === "true") return;

      editor.setAttribute("data-rich-text-ready", "true");
      editor.addEventListener("trix-attachment-add", function (event) {
        event.stopPropagation();
        uploadRichTextImage(editor, event.attachment);
      });
    });
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest("[data-screenshot-add]")) {
      installScreenshotInsertFields();
    }
  }, true);

  $(document).on("nested:fieldAdded:screenshots", "form", function (event) {
    var $field = $(event.field);
    if (!$field.closest("[data-screenshot-editor]").length) return;

    prepareScreenshotCard($field);
  });

  $(document).on("change", "[data-screenshot-file]", function () {
    var input = this;
    var file = input.files && input.files[0];
    if (!file) return;

    var $card = $(input).closest(".fields");
    var $image = $card.find("[data-screenshot-image]");
    var reader = new FileReader();

    reader.onload = function (event) {
      $image.attr("src", event.target.result).show();
      $card.find("[data-screenshot-placeholder]").hide();
    };

    reader.readAsDataURL(file);
    $card.find("[data-screenshot-filename]").text(file.name).attr("title", file.name);
    $card.find("[data-screenshot-status]").text("Ready to upload when you save");
    $card.find("[data-screenshot-upload-label]").text("Change image");
  });

  $(document).on("click", "[data-screenshot-remove]", function () {
    var $field = $(this).closest(".fields");
    $field.find("[data-screenshot-destroy]").val("1");
    $field.addClass("is-removed");
    refreshScreenshotEditor($field.closest("[data-screenshot-editor]"));
  });

  $(document).on("click", "[data-screenshot-undo]", function () {
    var $field = $(this).closest(".fields");
    $field.find("[data-screenshot-destroy]").val("0");
    $field.removeClass("is-removed");
    refreshScreenshotEditor($field.closest("[data-screenshot-editor]"));
  });

  $(document).on("click", "[data-copy-api-token]", function () {
    var input = document.querySelector("[data-api-token]");
    var status = document.querySelector("[data-api-token-copy-status]");
    if (!input) return;

    function reportCopy(message, isError) {
      if (!status) return;
      status.textContent = message;
      status.classList.toggle("is-error", Boolean(isError));
    }

    function fallbackCopy() {
      input.focus();
      input.select();
      input.setSelectionRange(0, input.value.length);

      try {
        if (!document.execCommand("copy")) throw new Error("Copy failed");
        reportCopy("Copied to clipboard.", false);
      } catch (_error) {
        reportCopy("Select and copy the key manually.", true);
      }
    }

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(input.value)
        .then(function () {
          reportCopy("Copied to clipboard.", false);
        })
        .catch(fallbackCopy);
    } else {
      fallbackCopy();
    }
  });

  $(document).on("submit", ".ie-api-key-form", function (event) {
    var form = this;
    var button = form.querySelector('button[type="submit"]');

    if (form.dataset.submitting === "true") {
      event.preventDefault();
      return;
    }

    form.dataset.submitting = "true";
    if (button) {
      button.disabled = true;
      button.innerHTML =
        '<i class="fas fa-circle-notch fa-spin" aria-hidden="true"></i> Issuing key...';
    }
  });

  $(function () {
    initializeAdminShell(document);
    initializeScreenshotEditors(document);
    initializeRichTextEditors(document);
  });

  document.addEventListener("rails_admin.dom_ready", function (event) {
    initializeAdminShell(event.detail || document);
    initializeScreenshotEditors(event.detail || document);
    initializeRichTextEditors(event.detail || document);
  });

  document.addEventListener("turbo:load", function () {
    initializeAdminShell(document);
    initializeScreenshotEditors(document);
    initializeRichTextEditors(document);
  });
})(jQuery);
