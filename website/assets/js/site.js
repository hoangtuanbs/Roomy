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
    var hub = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.46, 0.22, 48), metal);
    hub.position.y = 0.1; disk.add(hub);
    var hubHole = new THREE.Mesh(new THREE.CylinderGeometry(0.13, 0.13, 0.24, 32), new THREE.MeshStandardMaterial({ color: 0x0b0d28, roughness: 0.6 }));
    hubHole.position.y = 0.11; disk.add(hubHole);

    /* tone arm (from the icon) */
    var arm = new THREE.Group();
    var post = new THREE.Mesh(new THREE.CylinderGeometry(0.34, 0.38, 0.6, 40), metal); post.position.y = -0.1;
    var bar = new THREE.Mesh(new THREE.BoxGeometry(0.14, 0.1, 2.2), metal); bar.position.set(0, 0.3, -1.1);
    var headMesh = new THREE.Mesh(new THREE.BoxGeometry(0.3, 0.14, 0.4), metal); headMesh.position.set(0, 0.3, -2.25);
    arm.add(post, bar, headMesh);
    var ax = R * 0.95, az = R * 0.75;
    arm.position.set(ax, 0, az); var ARM_Y = Math.atan2(ax, az) - 0.32; arm.rotation.y = ARM_Y;
    world.add(arm);

    /* the treemap city: a home folder laid out like RoomyDisk's treemap */
    var COLORS = { vid: 0xf2789b, app: 0x7b8cff, doc: 0x5cc3ff, junk: 0xffb547, backup: 0xb48cff, mail: 0x8ad8c8 };
    var items = [
      { n: "Movies", s: 48, c: "vid" }, { n: "Photos Library", s: 36, c: "vid" },
      { n: "Applications", s: 22, c: "app" }, { n: "Docker", s: 18, c: "app" },
      { n: "Xcode DerivedData", s: 14, c: "junk", junk: true }, { n: "iPhone backup (old)", s: 12, c: "backup", junk: true },
      { n: "Documents", s: 11, c: "doc" }, { n: "Music", s: 9, c: "vid" }, { n: "Projects", s: 8, c: "app" },
      { n: "Old installers", s: 6, c: "junk", junk: true }, { n: "App caches", s: 5, c: "junk", junk: true },
      { n: "Mail", s: 4, c: "mail" }, { n: "npm cache", s: 3, c: "junk", junk: true }, { n: "Desktop", s: 2.5, c: "doc" },
      { n: "Logs", s: 1.2, c: "junk", junk: true }
    ];
    var junkTotal = items.reduce(function (a, it) { return a + (it.junk ? it.s : 0); }, 0);
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

    var SIDE = 4.3, GAP = 0.06;
    var blockGeo = new THREE.BoxGeometry(1, 1, 1);
    blockGeo.translate(0, 0.5, 0); // grow from the platter up
    var blocks = items.map(function (it, i) {
      var mat = new THREE.MeshPhysicalMaterial({
        color: COLORS[it.c], roughness: 0.32, metalness: 0.05, clearcoat: 1, clearcoatRoughness: 0.15,
        emissive: COLORS[it.c], emissiveIntensity: 0.08, transparent: true, opacity: 1
      });
      var m = new THREE.Mesh(blockGeo, mat);
      m.userData = {
        it: it, i: i,
        cur: { x: 0, z: 0, w: 0.01, d: 0.01, h: 0.001, y: 0, op: 1 },
        tgt: { x: 0, z: 0, w: 0.01, d: 0.01, h: 0.001, y: 0, op: 1 },
        vel: { x: 0, z: 0, w: 0, d: 0, h: 0, y: 0, op: 0 },
        delay: i * 0.06
      };
      disk.add(m);
      return m;
    });

    function relayout(includeJunk) {
      var list = items.filter(function (it) { return includeJunk || !it.junk; }).map(function (it) { return { v: it.s, it: it }; });
      var rects = squarify(list, -SIDE / 2, -SIDE / 2, SIDE, SIDE);
      var byItem = new Map(rects.map(function (r) { return [r.d.it, r]; }));
      blocks.forEach(function (b) {
        var r = byItem.get(b.userData.it), t = b.userData.tgt;
        if (r) {
          t.x = r.x + r.w / 2; t.z = r.y + r.h / 2; t.w = Math.max(0.02, r.w - GAP); t.d = Math.max(0.02, r.h - GAP);
          t.h = 0.1 + Math.sqrt(b.userData.it.s) * 0.12; t.y = 0; t.op = 1;
        }
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
      if (compact) { camera.fov = 30; world.scale.setScalar(1); world.position.set(0, baseY, 0); var f = w / h < 1 ? 1.12 : 1.05; camera.position.set(0, 11.5 * f, 12.5 * f); camera.lookAt(0, -0.5, 0); }
      else {
        camera.fov = 30; world.scale.setScalar(0.84);
        var aspect = w / h;
        world.position.set(Math.min(6.8, 3.1 + aspect * 1.8), baseY, 0.6); camera.position.set(0, 10.5, 13);
        camera.lookAt(world.position.x * 0.45, -0.6, 0);
      }
      camera.updateProjectionMatrix();
      if (reduceMotion) render();
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

    /* the story, on a loop: rise → scan → pick junk → clean → settle → junk creeps back */
    var CYCLE = 11.5, t0 = performance.now() / 1000, first = true, phase = "";
    relayout(true);
    function story(t) {
      var c = first ? t : (t % CYCLE);
      if (first && t > CYCLE) first = false;
      var freedFrac = 0, junkGlow = 0, sweepX = null;

      if (c < 2.2) { // rising (first time) or junk growing back
        if (phase !== "rise") { phase = "rise"; relayout(true); blocks.forEach(function (b) { if (b.userData.it.junk && !first) { var u = b.userData; u.cur.x = u.tgt.x; u.cur.z = u.tgt.z; u.cur.w = u.tgt.w; u.cur.d = u.tgt.d; u.cur.y = 0; u.cur.h = 0.001; u.cur.op = 0; u.vel.y = 0; } }); }
        setHud("Can be freed", junkTotal * Math.min(1, c / 2.2), 0);
      } else if (c < 4.4) { // scanning
        phase = "scan";
        sweepX = -SIDE / 2 - 0.3 + ((c - 2.2) / 2.2) * (SIDE + 0.6);
        junkGlow = Math.max(0, (c - 3.2) / 1.2);
        setHud("Can be freed", junkTotal, 0);
      } else if (c < 5.6) { // selected
        phase = "pick";
        junkGlow = 1;
      } else if (c < 7.4) { // clean: junk lifts away, city re-flows
        if (phase !== "clean") {
          phase = "clean";
          blocks.forEach(function (b) {
            if (b.userData.it.junk) { var tg = b.userData.tgt; tg.y = 3.2 + Math.random(); tg.op = 0; tg.w *= 0.2; tg.d *= 0.2; }
          });
          setTimeout(function () { if (phase === "clean") relayout(false); }, 420);
        }
        freedFrac = Math.min(1, (c - 5.6) / 1.6);
        var e = 1 - Math.pow(1 - freedFrac, 3);
        setHud("Freed", junkTotal * e, e);
      } else { // settled
        phase = "rest"; freedFrac = 1;
        setHud("Freed", junkTotal, 1);
      }

      // gauge: free share of the disk
      var freedGB = junkTotal * (phase === "clean" ? 1 - Math.pow(1 - freedFrac, 3) : freedFrac);
      setGauge((diskTotal - usedBase + freedGB) / diskTotal);

      // junk highlight
      blocks.forEach(function (b) {
        if (!b.userData.it.junk) return;
        var pulse = 0.5 + 0.5 * Math.sin(t * 7);
        b.material.emissive.setHex(junkGlow > 0 ? 0x3fe0a0 : COLORS[b.userData.it.c]);
        b.material.emissiveIntensity = junkGlow > 0 ? 0.25 + junkGlow * (0.35 + pulse * 0.35) : 0.08;
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
      var c = u.cur;
      b.position.set(c.x, c.y, c.z);
      b.scale.set(Math.max(0.001, c.w), Math.max(0.001, c.h), Math.max(0.001, c.d));
      b.material.opacity = Math.max(0, Math.min(1, c.op));
      b.visible = c.op > 0.02;
    }

    function settleInstantly() {
      relayout(true);
      blocks.forEach(function (b) { var u = b.userData; Object.keys(u.tgt).forEach(function (p) { u.cur[p] = u.tgt[p]; }); springStep(b, 0); });
      setGauge((diskTotal - usedBase) / diskTotal);
      blocks.forEach(function (b) { if (b.userData.it.junk) { b.material.emissive.setHex(0x3fe0a0); b.material.emissiveIntensity = 0.45; } });
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
      blocks.forEach(function (b) {
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
    }
    function setRunning(on) {
      if (on === running || reduceMotion) return;
      running = on;
      if (on) { last = performance.now(); requestAnimationFrame(frame); }
    }

    resize();
    hero.classList.add("is-3d");
    if (reduceMotion) { settleInstantly(); render(); return; }
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
