/* RoomyDisk website: 3D hero, scroll motion and the screen tour.
   Everything here is progressive: the page reads fine without it. */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var root = document.documentElement;
  root.classList.add("js");

  /* ---------------- nav background on scroll ---------------- */
  var nav = document.querySelector(".nav");
  function onScrollNav() { nav.classList.toggle("is-scrolled", window.scrollY > 24); }
  window.addEventListener("scroll", onScrollNav, { passive: true });
  onScrollNav();

  /* ---------------- reveal on scroll ---------------- */
  var reveals = [].slice.call(document.querySelectorAll("[data-reveal]"));
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el, i) {
      el.style.transitionDelay = (i % 3) * 80 + "ms";
      io.observe(el);
    });
  } else {
    reveals.forEach(function (el) { el.classList.add("is-in"); });
  }
  // Failsafe: never leave content hidden.
  setTimeout(function () {
    reveals.forEach(function (el) {
      var r = el.getBoundingClientRect();
      if (r.top < window.innerHeight) el.classList.add("is-in");
    });
  }, 2500);

  /* ---------------- contact form ---------------- */
  var form = document.getElementById("contactForm");
  if (form) {
    var note = document.getElementById("cf-note"), send = document.getElementById("cf-send");
    var fEmail = document.getElementById("cf-email"), fMsg = document.getElementById("cf-message");
    var EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
    function say(text, kind) { note.textContent = text; note.className = "contact__note" + (kind ? " is-" + kind : ""); }
    function mark(el, bad) { if (bad) el.setAttribute("aria-invalid", "true"); else el.removeAttribute("aria-invalid"); }
    [fEmail, fMsg].forEach(function (el) { el.addEventListener("input", function () { mark(el, false); }); });
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var badEmail = !EMAIL_RE.test(fEmail.value.trim()), badMsg = fMsg.value.trim().length < 10;
      mark(fEmail, badEmail); mark(fMsg, badMsg);
      if (badEmail) { say("Please enter an email address we can reply to.", "err"); fEmail.focus(); return; }
      if (badMsg) { say("Please write a few more words.", "err"); fMsg.focus(); return; }
      var data = {}; new FormData(form).forEach(function (v, k) { data[k] = v; });
      send.disabled = true; send.classList.add("is-busy"); say("Sending…");
      fetch(form.getAttribute("action"), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(data) })
        .then(function (r) { return r.json().catch(function () { return { ok: false }; }); })
        .then(function (res) {
          if (res.ok) { form.classList.add("is-sent"); say("Thanks! Your message is on its way. We'll reply by email.", "ok"); form.reset(); return; }
          if (res.field === "email") mark(fEmail, true);
          if (res.field === "message") mark(fMsg, true);
          say(res.error || "Your message couldn't be sent just now. Please try again in a minute.", "err");
        })
        .catch(function () { say("Your message couldn't be sent. Check your connection and try again.", "err"); })
        .then(function () { send.disabled = false; send.classList.remove("is-busy"); });
    });
  }

  /* ---------------- card tilt + spotlight ---------------- */
  if (!reduceMotion && window.matchMedia("(hover: hover)").matches) {
    [].forEach.call(document.querySelectorAll(".tilt"), function (card) {
      card.addEventListener("pointermove", function (ev) {
        var r = card.getBoundingClientRect();
        var px = (ev.clientX - r.left) / r.width, py = (ev.clientY - r.top) / r.height;
        card.style.setProperty("--mx", px * 100 + "%");
        card.style.setProperty("--my", py * 100 + "%");
        card.style.transform = "perspective(900px) rotateX(" + (0.5 - py) * 6 + "deg) rotateY(" + (px - 0.5) * 8 + "deg) translateZ(0)";
      });
      card.addEventListener("pointerleave", function () { card.style.transform = ""; });
    });
  }

  /* ---------------- screen tour ---------------- */
  var tabs = [].slice.call(document.querySelectorAll(".tabs [role=tab]"));
  var mac = document.getElementById("mac");
  var shotImg = document.getElementById("shotImg");
  var shotWebp = document.getElementById("shotWebp");
  var shotPanel = document.getElementById("shot");
  var cap = document.getElementById("shotCap");
  var current = 0, autoTimer = null, userPicked = false;

  // Preload so switching is instant.
  tabs.forEach(function (t) { var i = new Image(); i.src = "assets/img/" + t.dataset.shot + ".jpg"; });

  function select(i, fromUser) {
    if (i === current && fromUser !== "init") return;
    current = i;
    tabs.forEach(function (t, j) {
      t.setAttribute("aria-selected", j === i ? "true" : "false");
      t.tabIndex = j === i ? 0 : -1;
    });
    var t = tabs[i];
    shotPanel.setAttribute("aria-labelledby", t.id);
    mac.classList.add("is-swapping");
    setTimeout(function () {
      shotWebp.srcset = "assets/img/" + t.dataset.shot + ".webp";
      shotImg.src = "assets/img/" + t.dataset.shot + ".jpg";
      shotImg.alt = "RoomyDisk " + t.textContent + " screen";
      cap.textContent = t.dataset.cap;
      var done = function () { mac.classList.remove("is-swapping"); };
      if (shotImg.complete) requestAnimationFrame(done); else shotImg.onload = done;
    }, reduceMotion ? 0 : 220);
  }
  tabs.forEach(function (t, i) {
    t.tabIndex = i === 0 ? 0 : -1;
    t.addEventListener("click", function () { userPicked = true; stopAuto(); select(i, true); });
    t.addEventListener("keydown", function (ev) {
      var n = null;
      if (ev.key === "ArrowRight") n = (i + 1) % tabs.length;
      if (ev.key === "ArrowLeft") n = (i - 1 + tabs.length) % tabs.length;
      if (ev.key === "Home") n = 0;
      if (ev.key === "End") n = tabs.length - 1;
      if (n !== null) { ev.preventDefault(); userPicked = true; stopAuto(); tabs[n].focus(); select(n, true); }
    });
  });
  function startAuto() {
    if (reduceMotion || userPicked || autoTimer) return;
    autoTimer = setInterval(function () { select((current + 1) % tabs.length); }, 4200);
  }
  function stopAuto() { clearInterval(autoTimer); autoTimer = null; }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) startAuto(); else stopAuto(); });
    }, { threshold: 0.35 }).observe(mac);
  }

  /* ---------------- scroll-linked 3D window ---------------- */
  var stage = document.querySelector(".stage3d");
  var ticking = false;
  function updateMac() {
    ticking = false;
    var r = stage.getBoundingClientRect(), vh = window.innerHeight;
    // 0 when the window's top enters the bottom of the screen, 1 when its centre reaches 55% height.
    var p = (vh - r.top) / (vh * 0.45 + r.height * 0.5);
    p = Math.max(0, Math.min(1, p));
    var e = 1 - Math.pow(1 - p, 3);
    mac.style.setProperty("--rx", (1 - e) * 24 + "deg");
    mac.style.setProperty("--s", 0.86 + e * 0.14);
  }
  if (!reduceMotion) {
    window.addEventListener("scroll", function () { if (!ticking) { ticking = true; requestAnimationFrame(updateMac); } }, { passive: true });
    window.addEventListener("resize", updateMac);
    updateMac();
    if (window.matchMedia("(hover: hover)").matches) {
      stage.addEventListener("pointermove", function (ev) {
        var r = stage.getBoundingClientRect();
        mac.style.setProperty("--ry", ((ev.clientX - r.left) / r.width - 0.5) * 6 + "deg");
      });
      stage.addEventListener("pointerleave", function () { mac.style.setProperty("--ry", "0deg"); });
    }
  }

  /* ---------------- 3D hero ---------------- */
  function startHero() {
    var THREE = window.THREE;
    var hero = document.querySelector(".hero");
    var canvas = document.getElementById("disk3d");
    if (!THREE || !canvas) return;

    var renderer;
    try {
      renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true, powerPreference: "high-performance" });
    } catch (err) { return; } // keep the image fallback
    if (!renderer.getContext()) return;

    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.05;

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);

    /* studio reflections, built from a tiny scene so nothing is downloaded */
    var pmrem = new THREE.PMREMGenerator(renderer);
    var envScene = new THREE.Scene();
    envScene.background = new THREE.Color(0x5a6198);
    function panel(color, w, h, pos, look) {
      var m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: color, side: THREE.DoubleSide }));
      m.position.set(pos[0], pos[1], pos[2]); m.lookAt(look[0], look[1], look[2]); envScene.add(m);
    }
    panel(0xffffff, 14, 6, [0, 8, 2], [0, 0, 0]);
    panel(0xffffff, 10, 4, [5, 5, 6], [0, 0, 0]);
    panel(0xc8ceff, 6, 6, [-8, 2, 0], [0, 0, 0]);
    panel(0xff8fb0, 4, 6, [8, 3, -3], [0, 0, 0]);
    panel(0x9fffe0, 6, 2, [0, 1, -9], [0, 0, 0]);
    panel(0xdde2ff, 10, 2, [0, 3, 9], [0, 0, 0]);
    scene.environment = pmrem.fromScene(envScene, 0.04).texture;

    var key = new THREE.DirectionalLight(0xffffff, 1.6); key.position.set(4, 9, 6); scene.add(key);
    var rim = new THREE.DirectionalLight(0x8a7dff, 1.2); rim.position.set(-6, 3, -6); scene.add(rim);
    scene.add(new THREE.AmbientLight(0x404a9a, 0.6));

    var world = new THREE.Group(); scene.add(world);
    var disk = new THREE.Group(); world.add(disk);

    /* platter */
    var R = 3.3;
    var metal = new THREE.MeshPhysicalMaterial({ color: 0xd9dcef, metalness: 1, roughness: 0.22, clearcoat: 0.6, clearcoatRoughness: 0.2 });
    var platter = new THREE.Mesh(new THREE.CylinderGeometry(R, R, 0.22, 160, 1), metal);
    platter.position.y = -0.11; disk.add(platter);
    var base = new THREE.Mesh(new THREE.CylinderGeometry(R + 0.12, R + 0.18, 0.34, 160, 1),
      new THREE.MeshPhysicalMaterial({ color: 0x9aa0c8, metalness: 1, roughness: 0.35 }));
    base.position.y = -0.36; disk.add(base);

    // brushed rings on the platter top
    var grooveTex = (function () {
      var c = document.createElement("canvas"); c.width = c.height = 512;
      var g = c.getContext("2d"); g.translate(256, 256);
      for (var i = 0; i < 220; i++) {
        var rr = 20 + i * 1.07;
        g.strokeStyle = "rgba(" + (i % 3 ? "255,255,255" : "40,40,80") + "," + (0.03 + Math.random() * 0.05) + ")";
        g.beginPath(); g.arc(0, 0, rr, 0, Math.PI * 2); g.stroke();
      }
      var t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; return t;
    })();
    var grooves = new THREE.Mesh(new THREE.CircleGeometry(R - 0.02, 128),
      new THREE.MeshBasicMaterial({ map: grooveTex, transparent: true, depthWrite: false }));
    grooves.rotation.x = -Math.PI / 2; grooves.position.y = 0.002; disk.add(grooves);

    /* gauge arcs around the rim, like the app icon */
    var arcR = R + 0.42, tube = 0.13;
    var usedMat = new THREE.MeshPhysicalMaterial({ color: 0xff5d73, roughness: 0.25, clearcoat: 1, emissive: 0x401018 });
    var freeMat = new THREE.MeshPhysicalMaterial({ color: 0x3fe0a0, roughness: 0.25, clearcoat: 1, emissive: 0x0b4a33, emissiveIntensity: 1 });
    var trackMat = new THREE.MeshPhysicalMaterial({ color: 0x3a3f70, roughness: 0.5, metalness: 0.4 });
    var track = new THREE.Mesh(new THREE.TorusGeometry(arcR, tube * 0.7, 16, 200), trackMat);
    track.rotation.x = -Math.PI / 2; track.position.y = -0.2; disk.add(track);
    var usedArc = new THREE.Mesh(new THREE.BufferGeometry(), usedMat);
    var freeArc = new THREE.Mesh(new THREE.BufferGeometry(), freeMat);
    [usedArc, freeArc].forEach(function (m) { m.rotation.x = -Math.PI / 2; m.position.y = -0.2; disk.add(m); });
    var START = Math.PI * 0.62; // free space starts here and grows counter-clockwise
    var lastFree = -1;
    function setGauge(freeFrac) {
      freeFrac = Math.max(0.04, Math.min(0.96, freeFrac));
      if (Math.abs(freeFrac - lastFree) < 0.002) return;
      lastFree = freeFrac;
      var gap = 0.05, freeA = Math.PI * 2 * freeFrac, usedA = Math.PI * 2 - freeA - gap * 2;
      freeArc.geometry.dispose(); usedArc.geometry.dispose();
      freeArc.geometry = new THREE.TorusGeometry(arcR, tube, 16, Math.max(8, Math.round(freeA * 30)), freeA);
      usedArc.geometry = new THREE.TorusGeometry(arcR, tube, 16, Math.max(8, Math.round(usedA * 30)), usedA);
      freeArc.rotation.z = START; usedArc.rotation.z = START + freeA + gap;
    }

    /* hub */
    // (no hub: the folders cover the centre of the platter)

    /* tone arm (from the icon) */
    var arm = new THREE.Group();
    var post = new THREE.Mesh(new THREE.CylinderGeometry(0.34, 0.38, 0.6, 40), metal); post.position.y = -0.1;
    var bar = new THREE.Mesh(new THREE.BoxGeometry(0.14, 0.1, 2.2), metal); bar.position.set(0, 0.3, -1.1);
    var headMesh = new THREE.Mesh(new THREE.BoxGeometry(0.3, 0.14, 0.4), metal); headMesh.position.set(0, 0.3, -2.25);
    arm.add(post, bar, headMesh);
    var ax = R * 0.95, az = R * 0.75;
    arm.position.set(ax, 0, az); var ARM_Y = Math.atan2(ax, az) - 0.32; arm.rotation.y = ARM_Y;
    world.add(arm);

    /* the treemap: a home folder as folders (trays) holding files (tiles), drawn like RoomyDisk's treemap */
    var KINDS = {
      vid: { c: 0xf2789b, label: "Video" }, img: { c: 0xff9e6d, label: "Photos" }, music: { c: 0xd08cff, label: "Music" },
      app: { c: 0x7b8cff, label: "App" }, doc: { c: 0x5cc3ff, label: "Documents" }, mail: { c: 0x8ad8c8, label: "Mail" },
      junk: { c: 0xffc35c, label: "Junk" }, backup: { c: 0xb48cff, label: "Device backup" }
    };
    // [name, size in GB, kind, why RoomyDisk offers to remove it (only for junk)]
    var TREE = [
      { n: "Movies", files: [["holiday.mov", 31.5, "vid"], ["wedding-4k.mp4", 9.8, "vid"], ["screen recording.mov", 4.2, "vid"], ["trailer.m4v", 2.1, "vid"]] },
      { n: "Pictures", files: [["Photos Library", 27.4, "img"], ["RAW exports", 6.2, "img"], ["Screenshots", 1.9, "img"]] },
      { n: "Developer", files: [["Docker.raw", 16, "app"], ["DerivedData", 14.2, "junk", "Xcode build data"], ["node_modules", 3.8, "junk", "Untouched for 30 days"], ["roomy", 1.4, "doc"]] },
      { n: "Applications", files: [["Xcode.app", 11.6, "app"], ["Final Cut Pro.app", 5.2, "app"], ["Docker.app", 2.1, "app"], ["Figma.app", 0.9, "app"], ["Slack.app", 0.6, "app"]] },
      { n: "Library", files: [["iPhone backup 2025", 12.3, "backup", "Older iPhone backup"], ["Caches", 5.1, "junk", "App caches"], ["Mail", 4, "mail"], ["npm cache", 2.9, "junk", "Package cache"], ["Logs", 1.2, "junk", "Logs"]] },
      { n: "Documents", files: [["Projects", 6.5, "doc"], ["Scans", 2.2, "doc"], ["Thesis", 1.8, "doc"]] },
      { n: "Music", files: [["Music Library", 8.7, "music"]] },
      { n: "Downloads", files: [["Xcode_16.xip", 4.1, "junk", "Installer, 94 days old"], ["ubuntu-24.04.iso", 2.6, "junk", "Installer, 120 days old"], ["report-final.pdf", 0.4, "doc"], ["budget.xlsx", 0.2, "doc"]] }
    ];
    var diskTotal = 500, usedBase = 340; // a 500 GB disk with 160 GB free before cleaning

    function squarify(list, x, y, w, h) {
      var out = [], total = list.reduce(function (a, b) { return a + b.v; }, 0);
      var scale = (w * h) / total;
      var nodes = list.map(function (d) { return { d: d, a: d.v * scale }; });
      function worst(row, side) {
        var s = 0, mx = 0, mn = Infinity;
        row.forEach(function (r) { s += r.a; mx = Math.max(mx, r.a); mn = Math.min(mn, r.a); });
        return Math.max(side * side * mx / (s * s), (s * s) / (side * side * mn));
      }
      function layout(row, rx, ry, rw, rh) {
        var s = row.reduce(function (a, r) { return a + r.a; }, 0);
        if (rw >= rh) {
          var cw = s / rh, cy = ry;
          row.forEach(function (r) { var hh = r.a / cw; out.push({ d: r.d, x: rx, y: cy, w: cw, h: hh }); cy += hh; });
          return [rx + cw, ry, rw - cw, rh];
        }
        var ch = s / rw, cx = rx;
        row.forEach(function (r) { var ww = r.a / ch; out.push({ d: r.d, x: cx, y: ry, w: ww, h: ch }); cx += ww; });
        return [rx, ry + ch, rw, rh - ch];
      }
      var rect = [x, y, w, h], row = [];
      while (nodes.length) {
        var side = Math.min(rect[2], rect[3]), nxt = nodes[0];
        if (!row.length || worst(row.concat([nxt]), side) <= worst(row, side)) { row.push(nxt); nodes.shift(); }
        else { rect = layout(row, rect[0], rect[1], rect[2], rect[3]); row = []; }
      }
      if (row.length) layout(row, rect[0], rect[1], rect[2], rect[3]);
      return out;
    }

    var SIDE = 4.4, TRAY_H = 0.07, PAD = 0.075, GAP = 0.05;
    var nodeGeo = new THREE.BoxGeometry(1, 1, 1);
    nodeGeo.translate(0, 0.5, 0); // grow from the platter up
    function springData(delay) {
      function z() { return { x: 0, z: 0, w: 0.01, d: 0.01, h: 0.001, y: 0, op: 1 }; }
      return { cur: z(), tgt: z(), vel: { x: 0, z: 0, w: 0, d: 0, h: 0, y: 0, op: 0 }, delay: delay, lift: 0, liftCur: 0 };
    }
    function gb(v) { return v >= 10 ? v.toFixed(0) + " GB" : v >= 1 ? v.toFixed(1) + " GB" : Math.round(v * 1000) + " MB"; }

    var labelsEl = document.createElement("div"); labelsEl.className = "labels";
    canvas.parentNode.appendChild(labelsEl);
    function tag(cls, html) { var e = document.createElement("span"); e.className = "tag " + cls; e.innerHTML = html; e.style.opacity = 0; labelsEl.appendChild(e); return e; }

    var folders = [], files = [];
    TREE.forEach(function (fd, fi) {
      var tray = new THREE.Mesh(nodeGeo, new THREE.MeshPhysicalMaterial({ color: 0x2a3070, roughness: 0.35, metalness: 0.35, clearcoat: 0.8, transparent: true }));
      tray.userData = springData(fi * 0.05);
      tray.userData.folder = fd;
      tray.userData.label = tag("tag--folder", "<i></i>" + fd.n + "<b></b>");
      disk.add(tray); folders.push(tray);
      fd.files.forEach(function (f, j) {
        var k = KINDS[f[2]];
        var shade = new THREE.Color(k.c).offsetHSL(0, 0, [0, 0.07, -0.06, 0.12, -0.1][j % 5]);
        var m = new THREE.Mesh(nodeGeo, new THREE.MeshPhysicalMaterial({
          color: shade, roughness: 0.3, metalness: 0.05, clearcoat: 1, clearcoatRoughness: 0.12,
          emissive: shade, emissiveIntensity: 0.06, transparent: true
        }));
        m.userData = springData(0.3 + fi * 0.06 + j * 0.05);
        m.userData.file = { n: f[0], s: f[1], kind: f[2], why: f[3] || null, junk: !!f[3], folder: fd.n };
        disk.add(m); files.push(m);
      });
    });
    var nodes = folders.concat(files);
    var junkFiles = files.filter(function (m) { return m.userData.file.junk; });
    var junkTotal = junkFiles.reduce(function (a, m) { return a + m.userData.file.s; }, 0);
    // the four biggest finds get a callout; the rest just glow
    junkFiles.slice().sort(function (p, q) { return q.userData.file.s - p.userData.file.s; }).slice(0, 4).forEach(function (m) {
      var f = m.userData.file;
      m.userData.label = tag("tag--junk", f.n + "<b>" + gb(f.s) + "</b><em>" + f.why + "</em>");
    });

    function bySize(p, q) { return q.v - p.v; }
    function relayout(includeJunk) {
      var list = folders.map(function (tr) {
        var fl = files.filter(function (m) { return m.userData.file.folder === tr.userData.folder.n && (includeJunk || !m.userData.file.junk); })
          .map(function (m) { return { v: m.userData.file.s, m: m }; }).sort(bySize);
        return { v: fl.reduce(function (a, x) { return a + x.v; }, 0), tr: tr, fl: fl };
      }).filter(function (x) { return x.v > 0; }).sort(bySize);
      squarify(list, -SIDE / 2, -SIDE / 2, SIDE, SIDE).forEach(function (r) {
        var tr = r.d.tr, t = tr.userData.tgt;
        t.x = r.x + r.w / 2; t.z = r.y + r.h / 2; t.w = r.w - GAP; t.d = r.h - GAP; t.h = TRAY_H; t.y = 0; t.op = 1;
        tr.userData.label.querySelector("b").textContent = gb(r.d.v);
        var iw = Math.max(0.02, r.w - GAP - PAD * 2), ih = Math.max(0.02, r.h - GAP - PAD * 2);
        squarify(r.d.fl, r.x + GAP / 2 + PAD, r.y + GAP / 2 + PAD, iw, ih).forEach(function (q) {
          var u = q.d.m.userData, ft = u.tgt;
          ft.x = q.x + q.w / 2; ft.z = q.y + q.h / 2;
          ft.w = Math.max(0.015, q.w - 0.065); ft.d = Math.max(0.015, q.h - 0.065);
          ft.h = 0.05 + Math.sqrt(u.file.s) * 0.12; ft.y = TRAY_H; ft.op = 1;
        });
      });
    }

    /* contact shadow and dust */
    var shadowTex = (function () {
      var c = document.createElement("canvas"); c.width = c.height = 256;
      var g = c.getContext("2d"), grd = g.createRadialGradient(128, 128, 10, 128, 128, 128);
      grd.addColorStop(0, "rgba(0,0,10,.75)"); grd.addColorStop(0.6, "rgba(0,0,10,.3)"); grd.addColorStop(1, "rgba(0,0,10,0)");
      g.fillStyle = grd; g.fillRect(0, 0, 256, 256);
      return new THREE.CanvasTexture(c);
    })();
    var shadow = new THREE.Mesh(new THREE.PlaneGeometry(R * 3.4, R * 3.4), new THREE.MeshBasicMaterial({ map: shadowTex, transparent: true, depthWrite: false }));
    shadow.rotation.x = -Math.PI / 2; shadow.position.y = -0.62; world.add(shadow);

    var dustGeo = new THREE.BufferGeometry(), N = 160, pos = new Float32Array(N * 3);
    for (var k = 0; k < N; k++) { pos[k * 3] = (Math.random() - 0.5) * 16; pos[k * 3 + 1] = Math.random() * 7 - 1; pos[k * 3 + 2] = (Math.random() - 0.5) * 12; }
    dustGeo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    var dust = new THREE.Points(dustGeo, new THREE.PointsMaterial({ color: 0xaab4ff, size: 0.035, transparent: true, opacity: 0.55, depthWrite: false }));
    scene.add(dust);

    /* scan sweep: a thin glowing blade that passes over the city */
    var sweep = new THREE.Mesh(new THREE.BoxGeometry(0.035, 1.3, SIDE + 0.3),
      new THREE.MeshBasicMaterial({ color: 0x9fffe0, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false }));
    sweep.position.y = 0.65; disk.add(sweep);
    var sweepGlow = new THREE.PointLight(0x3fe0a0, 0, 5); disk.add(sweepGlow);

    /* layout + responsiveness */
    var compact = false, baseY = 0;
    function resize() {
      var w = canvas.clientWidth, h = canvas.clientHeight;
      if (!w || !h) return;
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      compact = w < 900;
      baseY = compact ? 0 : -0.2;
      if (compact) { camera.fov = 30; world.scale.setScalar(1); world.position.set(0, baseY, 0); var f = w / h < 1 ? 0.98 : 1.0; camera.position.set(0, 11.5 * f, 12.5 * f); camera.lookAt(0, -0.5, 0); }
      else {
        camera.fov = 30; world.scale.setScalar(0.84);
        var aspect = w / h;
        world.position.set(Math.min(6.8, 3.1 + aspect * 1.8), baseY, 0.6); camera.position.set(0, 10.5, 13);
        camera.lookAt(world.position.x * 0.45, -0.6, 0);
      }
      camera.updateProjectionMatrix();
    }
    window.addEventListener("resize", resize);

    /* pointer parallax */
    var pointer = { x: 0, y: 0 }, smooth = { x: 0, y: 0 };
    window.addEventListener("pointermove", function (ev) {
      pointer.x = ev.clientX / window.innerWidth - 0.5;
      pointer.y = ev.clientY / window.innerHeight - 0.5;
    }, { passive: true });

    /* HUD */
    var hudFree = document.getElementById("hudFree");
    var hudLabel = document.querySelector(".hud__label");
    var hudBar = document.getElementById("hudBar");
    function setHud(label, gb, frac) {
      hudLabel.textContent = label;
      hudFree.textContent = gb.toFixed(1) + " GB";
      hudBar.style.width = Math.round(frac * 100) + "%";
    }

    /* the story, on a loop: rise → the scan finds junk file by file → clean → settle → junk creeps back */
    var CYCLE = 13, t0 = performance.now() / 1000, first = true, phase = "";
    relayout(true);
    function resetJunk() {
      junkFiles.forEach(function (m) {
        var u = m.userData; u.found = false;
        if (!first) { u.cur.x = u.tgt.x; u.cur.z = u.tgt.z; u.cur.w = u.tgt.w; u.cur.d = u.tgt.d; u.cur.y = TRAY_H; u.cur.h = 0.001; u.cur.op = 0; u.vel.y = 0; u.vel.h = 0; }
      });
    }
    function story(t) {
      var c = first ? t : (t % CYCLE);
      if (first && t > CYCLE) first = false;
      var freedFrac = 0, sweepX = null;

      if (c < 2.4) { // rising (first time) or junk growing back
        if (phase !== "rise") { phase = "rise"; relayout(true); resetJunk(); }
        setHud("Scanning…", 0, 0);
      } else if (c < 5.2) { // the scanner finds each junk file as it passes
        phase = "scan";
        sweepX = -SIDE / 2 - 0.3 + ((c - 2.4) / 2.6) * (SIDE + 0.6);
        var found = 0;
        junkFiles.forEach(function (m) { if (m.userData.cur.x < sweepX) m.userData.found = true; if (m.userData.found) found += m.userData.file.s; });
        setHud("Can be freed", found, 0);
      } else if (c < 6.6) { // all picked
        phase = "pick";
        junkFiles.forEach(function (m) { m.userData.found = true; });
        setHud("Can be freed", junkTotal, 0);
      } else if (c < 8.6) { // clean: junk lifts away, folders re-flow
        if (phase !== "clean") {
          phase = "clean";
          junkFiles.forEach(function (m, i) {
            var tg = m.userData.tgt; tg.y = 2.8 + (i % 3) * 0.35; tg.op = 0; tg.w *= 0.25; tg.d *= 0.25;
          });
          setTimeout(function () { if (phase === "clean") relayout(false); }, 450);
        }
        freedFrac = Math.min(1, (c - 6.6) / 1.7);
        var e = 1 - Math.pow(1 - freedFrac, 3);
        setHud("Freed", junkTotal * e, e);
      } else { // settled
        phase = "rest"; freedFrac = 1;
        setHud("Freed", junkTotal, 1);
      }

      // gauge: free share of the disk
      var freedGB = junkTotal * (phase === "clean" ? 1 - Math.pow(1 - freedFrac, 3) : freedFrac);
      setGauge((diskTotal - usedBase + freedGB) / diskTotal);

      // found junk glows green and pulses
      var pulse = 0.5 + 0.5 * Math.sin(t * 7);
      junkFiles.forEach(function (m) {
        var on = m.userData.found && phase !== "rise";
        if (on) m.material.emissive.setHex(0x3fe0a0); else m.material.emissive.copy(m.material.color);
        m.material.emissiveIntensity = on ? 0.45 + pulse * 0.35 : 0.06;
      });

      if (sweepX === null) { sweep.material.opacity *= 0.85; sweepGlow.intensity *= 0.85; }
      else { sweep.position.x = sweepX; sweep.material.opacity = 0.7; sweepGlow.position.set(sweepX, 1.2, 0); sweepGlow.intensity = 6; }
    }

    /* springs */
    function springStep(b, dt) {
      var u = b.userData, k = 90, damp = 14;
      ["x", "z", "w", "d", "h", "y", "op"].forEach(function (p) {
        var a = (u.tgt[p] - u.cur[p]) * k - u.vel[p] * damp;
        u.vel[p] += a * dt; u.cur[p] += u.vel[p] * dt;
      });
      u.liftCur += (u.lift - u.liftCur) * Math.min(1, dt * 14);
      var c = u.cur;
      b.position.set(c.x, c.y + u.liftCur, c.z);
      b.scale.set(Math.max(0.001, c.w), Math.max(0.001, c.h), Math.max(0.001, c.d));
      b.material.opacity = Math.max(0, Math.min(1, c.op));
      b.visible = c.op > 0.02;
    }

    /* labels: folder names on their trays, callouts on what the scan finds */
    var v3 = new THREE.Vector3();
    function toScreen(x, y, z) {
      v3.set(x, y, z); disk.localToWorld(v3); v3.project(camera);
      return [(v3.x + 1) / 2 * canvas.clientWidth, (1 - v3.y) / 2 * canvas.clientHeight];
    }
    function place(el, p, op) {
      el.style.opacity = op;
      if (op > 0) el.style.transform = "translate(" + p[0].toFixed(1) + "px," + p[1].toFixed(1) + "px)";
    }
    var shown = [];
    function updateLabels() {
      var minW = compact ? 82 : 84;
      folders.forEach(function (tr) {
        var c = tr.userData.cur, el = tr.userData.label;
        var a = toScreen(c.x - c.w / 2, TRAY_H, c.z + c.d / 2), b = toScreen(c.x + c.w / 2, TRAY_H, c.z + c.d / 2);
        var wide = Math.hypot(b[0] - a[0], b[1] - a[1]) >= minW && c.op > 0.5;
        place(el, toScreen(c.x - c.w / 2 + 0.05, TRAY_H, c.z + c.d / 2 - 0.03), wide ? (phase === "scan" || phase === "pick" ? 0.45 : 1) : 0);
      });
      junkFiles.forEach(function (m) {
        var el = m.userData.label; if (!el) return;
        var c = m.userData.cur, on = m.userData.found && (phase === "scan" || phase === "pick");
        var p = toScreen(c.x, c.y + c.h + m.userData.liftCur, c.z);
        if (on) shown.push({ el: el, x: p[0], y: p[1], w: el.offsetWidth, h: el.offsetHeight + 16 });
        else place(el, p, 0);
      });
      // keep callouts from covering each other: nudge later ones upward
      shown.sort(function (a, b) { return b.y - a.y; });
      for (var i = 0; i < shown.length; i++) {
        for (var j = 0; j < i; j++) {
          var A = shown[i], B = shown[j];
          if (Math.abs(A.x - B.x) < (A.w + B.w) / 2 + 6 && A.y > B.y - B.h && A.y - A.h < B.y) A.y = B.y - B.h;
        }
        place(shown[i].el, [shown[i].x, shown[i].y], 1);
      }
      shown.length = 0;
    }

    /* hover (or tap) a file to see what it is */
    var tip = document.createElement("div"); tip.className = "tip"; tip.style.opacity = 0; labelsEl.appendChild(tip);
    var ray = new THREE.Raycaster(), ndc = new THREE.Vector2(), hovered = null, tipTimer = null;
    function pick(ev) {
      var r = canvas.getBoundingClientRect();
      if (ev.clientX < r.left || ev.clientX > r.right || ev.clientY < r.top || ev.clientY > r.bottom) return null;
      ndc.set((ev.clientX - r.left) / r.width * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
      ray.setFromCamera(ndc, camera);
      var hit = ray.intersectObjects(files.filter(function (m) { return m.visible && m.userData.cur.op > 0.5; }), false)[0];
      return hit ? { m: hit.object, x: ev.clientX - r.left, y: ev.clientY - r.top } : null;
    }
    function hex(n) { return "#" + ("00000" + n.toString(16)).slice(-6); }
    function showTip(h) {
      if (hovered && (!h || hovered !== h.m)) hovered.userData.lift = 0;
      hovered = h ? h.m : null;
      canvas.style.cursor = h ? "pointer" : "";
      if (!h) { tip.style.opacity = 0; return; }
      var f = h.m.userData.file; h.m.userData.lift = 0.14;
      tip.innerHTML = '<span class="tip__path mono">~/' + f.folder + "/" + f.n + '</span><b class="mono">' + gb(f.s) + "</b>" +
        '<span class="tip__kind"><i style="background:' + hex(KINDS[f.kind].c) + '"></i>' + KINDS[f.kind].label + "</span>" +
        (f.junk ? '<span class="tip__why">RoomyDisk can free this: ' + f.why.toLowerCase() + "</span>" : "");
      var x = Math.max(8, Math.min(h.x + 16, canvas.clientWidth - 260)), y = Math.max(8, h.y - 84);
      tip.style.transform = "translate(" + x + "px," + y + "px)"; tip.style.opacity = 1;
    }
    canvas.addEventListener("pointermove", function (ev) { if (ev.pointerType === "mouse") showTip(pick(ev)); });
    canvas.addEventListener("pointerleave", function () { showTip(null); });
    canvas.addEventListener("pointerup", function (ev) {
      if (ev.pointerType === "mouse") return;
      showTip(pick(ev)); clearTimeout(tipTimer); tipTimer = setTimeout(function () { showTip(null); }, 2600);
    });

    function settleInstantly() {
      relayout(true);
      nodes.forEach(function (b) { var u = b.userData; Object.keys(u.tgt).forEach(function (p) { u.cur[p] = u.tgt[p]; }); springStep(b, 0); });
      setGauge((diskTotal - usedBase) / diskTotal);
      phase = "pick";
      junkFiles.forEach(function (m) { m.userData.found = true; m.material.emissive.setHex(0x3fe0a0); m.material.emissiveIntensity = 0.6; });
      setHud("Can be freed", junkTotal, 0);
      disk.rotation.y = -0.5;
    }

    function render() { renderer.render(scene, camera); }

    var running = false, visible = true, last = performance.now();
    function frame(now) {
      if (!running) return;
      requestAnimationFrame(frame);
      var dt = Math.min(0.05, (now - last) / 1000); last = now;
      var t = now / 1000 - t0;

      story(t);
      nodes.forEach(function (b) {
        // stagger the very first rise
        if (first && t < b.userData.delay) return;
        springStep(b, dt);
      });

      disk.rotation.y = -0.5 + Math.sin(t * 0.15) * 0.35;
      smooth.x += (pointer.x - smooth.x) * 0.05; smooth.y += (pointer.y - smooth.y) * 0.05;
      world.rotation.y = smooth.x * 0.35;
      world.rotation.x = smooth.y * 0.12;
      var sc = Math.min(1, window.scrollY / (window.innerHeight * 0.9));
      world.rotation.z = -sc * 0.15;
      world.position.y = baseY + sc * 1.6;
      dust.rotation.y = t * 0.02;
      dust.position.y = Math.sin(t * 0.3) * 0.15;
      arm.rotation.y += ((ARM_Y + (phase === "scan" ? 0.16 : 0) + Math.sin(t * 0.4) * 0.03) - arm.rotation.y) * 0.06;

      render();
      updateLabels();
    }
    function setRunning(on) {
      if (on === running || reduceMotion) return;
      running = on;
      if (on) { last = performance.now(); requestAnimationFrame(frame); }
    }

    resize();
    hero.classList.add("is-3d");
    if (reduceMotion) {
      settleInstantly(); render(); updateLabels();
      window.addEventListener("resize", function () { render(); updateLabels(); });
      canvas.addEventListener("pointermove", function () { requestAnimationFrame(function () { nodes.forEach(function (b) { b.userData.liftCur = b.userData.lift; springStep(b, 0); }); render(); updateLabels(); }); });
      return;
    }
    setRunning(true);

    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) { visible = es[0].isIntersecting; setRunning(visible && !document.hidden); }, { threshold: 0 }).observe(hero);
    }
    document.addEventListener("visibilitychange", function () { setRunning(visible && !document.hidden); });
    canvas.addEventListener("webglcontextlost", function (ev) { ev.preventDefault(); running = false; hero.classList.remove("is-3d"); });
  }

  if (document.readyState === "complete") startHero();
  else window.addEventListener("load", startHero);
})();
