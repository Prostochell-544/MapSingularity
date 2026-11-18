/*
 * MapSingularity — гиперпространственный тоннель для экрана загрузки GMod.
 * Без внешних зависимостей: один <canvas> поверх страницы, ES5 (старые сборки CEF).
 * В коде только ASCII: меню GMod читает страницу без charset (как windows-1252).
 *
 *   MSTunnel.start({ fadeIn: 0.8, speed: 1 })  — запустить
 *   MSTunnel.stop()                             — остановить и убрать
 *
 * Режим патча хоста: строка
 *   <script src="ms_tunnel.js" data-ms-host></script>
 * в конце garrysmod/html/loading.html. Тоннель включается по ранней отметке в
 * localStorage (ms_prime.html) или по метке U+2063 в имени сервера из GameDetails.
 *
 * Пока движок грузит карту, страница перерисовывается рывками (несколько кадров в
 * секунду). Поэтому всё движение считается от реального времени, а не от числа
 * кадров: при любом FPS скорость полёта одна и та же, а длина звёздных полос задана
 * временем, а не расстоянием между кадрами.
 */
(function (root, doc) {
	'use strict';

	var MARKER = String.fromCharCode(0x2063); // U+2063 INVISIBLE SEPARATOR, ASCII-only on purpose
	var HOST_WAIT_MS = 700;   // сколько держать чёрную шторку без сигнала
	var PRIME_KEY = 'ms_transit';
	var PRIME_MAX_AGE_MS = 120000;

	var STAR_COUNT = 640;
	var RING_COUNT = 22;
	var DEPTH = 30;           // глубина звёздного поля в условных единицах
	var FOCAL = 0.85;         // фокус проекции относительно min(w, h)
	var RES_SCALE = 0.7;      // внутреннее разрешение холста относительно экрана
	var TRAIL_TIME = 0.07;    // длина полосы звезды — путь за столько секунд
	var BUCKETS = 6;          // звёзды рисуются пачками по яркости: 2 цвета x 6 = 12 штрихов
	var HUES = [195, 268];    // голубые и фиолетовые

	var canvas = null, ctx = null, raf = 0;
	var w = 0, h = 0, px = 1;
	var stars = [], rings = [], batches = [];
	var startTime = 0, lastTime = 0, travel = 0;
	var settings = null;

	function rand(a, b) { return a + Math.random() * (b - a); }
	function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
	function smooth(x) { x = clamp01(x); return x * x * (3 - 2 * x); }
	function now() { return (root.performance && root.performance.now) ? root.performance.now() : Date.now(); }

	function placeStar(s) {
		var ang = Math.random() * Math.PI * 2;
		var r = 0.08 + Math.pow(Math.random(), 0.55) * 1.7; // пустое «горло» в центре
		s.x = Math.cos(ang) * r;
		s.y = Math.sin(ang) * r;
		s.group = Math.random() < 0.25 ? 0 : 1;
	}

	function build() {
		stars = [];
		for (var i = 0; i < STAR_COUNT; i++) {
			var s = { z0: Math.random() * DEPTH, cycle: 0 };
			placeStar(s);
			stars.push(s);
		}
		rings = [];
		for (var j = 0; j < RING_COUNT; j++) {
			rings.push({ z0: (j + 0.5) * DEPTH / RING_COUNT, twist: Math.random() * Math.PI, hue: j % 3 === 0 ? 195 : 265, cycle: 0 });
		}
		batches = [];
		for (var g = 0; g < HUES.length; g++) {
			for (var b = 0; b < BUCKETS; b++) {
				var near = (b + 0.5) / BUCKETS;
				batches.push({
					style: 'hsla(' + HUES[g] + ',85%,' + Math.round(70 + 25 * near) + '%,' + clamp01(near * 1.3).toFixed(3) + ')',
					width: Math.max(0.7, 2.6 * near),
					segs: []
				});
			}
		}
	}

	function resize() {
		px = RES_SCALE;
		w = Math.max(1, Math.floor(root.innerWidth * RES_SCALE));
		h = Math.max(1, Math.floor(root.innerHeight * RES_SCALE));
		canvas.width = w;
		canvas.height = h;
		ctx.fillStyle = '#000';
		ctx.fillRect(0, 0, w, h);
	}

	// Позиция по глубине с переходом через край поля: z0 - travel по модулю DEPTH.
	// Номер «круга» меняется при каждом проходе — тогда звезда получает новое место.
	function wrapDepth(item, z0, distance) {
		var raw = z0 - distance;
		var cycle = Math.floor(raw / DEPTH);
		var z = raw - cycle * DEPTH;
		var renewed = cycle !== item.cycle;
		item.cycle = cycle;
		return { z: z, renewed: renewed };
	}

	function speedAt(t) {
		// Разгон: прыжок ощущается как ускорение, а не как заставка.
		return settings.speed * (6 + 18 * smooth(t / 2.5));
	}

	function frame(time) {
		raf = root.requestAnimationFrame(frame);

		// Реальное время между кадрами; даже если страница «замёрзла» на секунду,
		// дальше движение продолжается с правильной скоростью.
		var dt = Math.min((time - lastTime) / 1000, 1);
		if (dt < 0) dt = 0;
		lastTime = time;
		var t = (time - startTime) / 1000;
		var speed = speedAt(t);
		travel += speed * dt;

		var cx = w * 0.5 + Math.sin(t * 0.6) * w * 0.012;
		var cy = h * 0.5 + Math.cos(t * 0.45) * h * 0.012;
		var f = Math.min(w, h) * FOCAL;
		var k, a, item, d;

		// Хвосты от прошлых кадров: доля затирания зависит от прошедшего времени,
		// поэтому при редких кадрах шлейф не растягивается в кашу.
		ctx.globalCompositeOperation = 'source-over';
		var fade = 1 - Math.pow(0.68, dt * 60);
		ctx.fillStyle = 'rgba(0,0,0,' + Math.max(0.32, Math.min(1, fade)).toFixed(3) + ')';
		ctx.fillRect(0, 0, w, h);

		ctx.globalCompositeOperation = 'lighter';

		// Кольца тоннеля, набегающие на камеру.
		for (k = 0; k < rings.length; k++) {
			item = rings[k];
			d = wrapDepth(item, item.z0, travel * 0.55);
			if (d.renewed) item.twist = Math.random() * Math.PI;
			var rz = d.z + 0.5;

			var rr = f * 1.15 / rz;
			if (rr > Math.max(w, h) * 1.5) continue;
			a = 0.28 * smooth(1 - rz / DEPTH) * smooth((rz - 0.5) / 2.5);
			if (a <= 0.004) continue;

			ctx.lineWidth = Math.max(1, (5 * px) / Math.sqrt(rz));
			ctx.strokeStyle = 'hsla(' + item.hue + ',90%,62%,' + a.toFixed(3) + ')';
			ctx.beginPath();
			ctx.ellipse(cx, cy, rr, rr * 0.9, item.twist + t * 0.15, 0, Math.PI * 2);
			ctx.stroke();
		}

		// Звёзды-полосы: голова — текущая глубина, хвост — где звезда была TRAIL_TIME назад.
		for (k = 0; k < batches.length; k++) batches[k].segs.length = 0;

		var tail = speed * TRAIL_TIME;
		for (k = 0; k < stars.length; k++) {
			item = stars[k];
			d = wrapDepth(item, item.z0, travel);
			if (d.renewed) placeStar(item);
			var z = d.z;
			if (z < 0.3) continue;

			var sx = cx + (item.x / z) * f, sy = cy + (item.y / z) * f;
			if (sx < -50 || sx > w + 50 || sy < -50 || sy > h + 50) continue;
			var tz = z + tail;
			var bucket = Math.min(BUCKETS - 1, Math.floor((1 - z / DEPTH) * BUCKETS));
			batches[item.group * BUCKETS + bucket].segs.push(cx + (item.x / tz) * f, cy + (item.y / tz) * f, sx, sy);
		}

		for (k = 0; k < batches.length; k++) {
			var batch = batches[k];
			if (!batch.segs.length) continue;
			ctx.strokeStyle = batch.style;
			ctx.lineWidth = batch.width * px;
			ctx.beginPath();
			for (var i = 0; i < batch.segs.length; i += 4) {
				ctx.moveTo(batch.segs[i], batch.segs[i + 1]);
				ctx.lineTo(batch.segs[i + 2], batch.segs[i + 3]);
			}
			ctx.stroke();
		}

		// Сингулярность в конце тоннеля: заливаем только квадрат вокруг свечения.
		var pulse = 0.85 + 0.15 * Math.sin(t * 3.1);
		var gr = f * 0.32 * pulse;
		var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, gr);
		g.addColorStop(0, 'rgba(235,225,255,0.55)');
		g.addColorStop(0.25, 'rgba(150,105,255,0.22)');
		g.addColorStop(1, 'rgba(0,0,0,0)');
		ctx.fillStyle = g;
		ctx.fillRect(cx - gr, cy - gr, gr * 2, gr * 2);

		// Плавное появление из чёрного — стык с затемнением в игре.
		ctx.globalCompositeOperation = 'source-over';
		var cover = 1 - smooth(t / settings.fadeIn);
		if (cover > 0) {
			ctx.fillStyle = 'rgba(0,0,0,' + cover.toFixed(3) + ')';
			ctx.fillRect(0, 0, w, h);
		}
	}

	function start(options) {
		if (canvas) return;
		options = options || {};
		settings = {
			fadeIn: options.fadeIn > 0 ? options.fadeIn : 0.8,
			speed: options.speed > 0 ? options.speed : 1
		};

		canvas = doc.createElement('canvas');
		canvas.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;z-index:2147483647;background:#000;display:block;';
		ctx = canvas.getContext('2d');
		doc.body.appendChild(canvas);

		build();
		resize();
		root.addEventListener('resize', resize);

		travel = 0;
		startTime = lastTime = now();
		raf = root.requestAnimationFrame(frame);
		MSTunnel.active = true;
	}

	function stop() {
		if (!canvas) return;
		root.cancelAnimationFrame(raf);
		root.removeEventListener('resize', resize);
		if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
		canvas = ctx = null;
		MSTunnel.active = false;
	}

	// Диагностика в консоль GMod: меню пересылает сообщения страниц строками "[HTML] ...".
	// Только ASCII — кодировку пересылки не контролируем.
	function diag(msg) {
		try { if (root.console && root.console.warn) root.console.warn('[MapSingularity] ' + msg); } catch (e) { /* без консоли — молча */ }
	}

	function describe(name) {
		if (typeof name !== 'string') return typeof name;
		var codes = [];
		for (var i = Math.max(0, name.length - 3); i < name.length; i++) codes.push('U+' + name.charCodeAt(i).toString(16).toUpperCase());
		return 'len=' + name.length + ' tail=' + codes.join(',');
	}

	// Ранний сигнал «это прыжок»: клиент аддона за ~1.8 с до changelevel открывает
	// невидимую страницу ms_prime.html того же origin (asset://garrysmod), та пишет
	// отметку времени в localStorage. При смене карты меню вызывает GameDetails поздно —
	// после загрузки сервера, — а отметка доступна сразу при открытии страницы.
	function takePrime() {
		try {
			var stamp = Number(root.localStorage.getItem(PRIME_KEY) || 0);
			root.localStorage.removeItem(PRIME_KEY);
			var age = Date.now() - stamp;
			diag('prime ' + (stamp ? 'age=' + age + 'ms' : 'absent'));
			return stamp > 0 && age >= 0 && age < PRIME_MAX_AGE_MS;
		} catch (e) {
			diag('prime unavailable: ' + e);
			return false;
		}
	}

	// Патч хоста. Решение «тоннель или обычная страница»:
	//   1) отметка в localStorage — сразу при открытии страницы;
	//   2) метка в имени сервера из GameDetails — когда бы он ни пришёл;
	//   3) ничего за HOST_WAIT_MS — показываем обычную страницу (позже её ещё может
	//      сменить тоннель по п. 2).
	function installHostHook() {
		var primed = takePrime();
		diag('host patch active, primed=' + (primed ? 'yes' : 'no'));

		var shade = doc.createElement('div');
		shade.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;background:#000;z-index:2147483646;transition:opacity .25s;';
		doc.body.appendChild(shade);

		var revealed = false;
		var fromPrime = false;
		function dropShade() {
			if (shade.parentNode) shade.parentNode.removeChild(shade);
		}
		function reveal() {
			if (revealed || MSTunnel.active) return;
			revealed = true;
			shade.style.opacity = '0';
			root.setTimeout(dropShade, 300);
		}
		function tunnel() {
			if (MSTunnel.active) return;
			start({ fadeIn: 0.6 });
			dropShade();
		}

		if (primed) {
			fromPrime = true;
			tunnel();
		}

		var original = root.GameDetails;
		root.GameDetails = function (servername) {
			var hit = typeof servername === 'string' && servername.indexOf(MARKER) !== -1;
			diag('GameDetails ' + describe(servername) + ' marker=' + (hit ? 'yes' : 'no') + ' tunnel=' + (MSTunnel.active ? 'on' : 'off'));
			if (hit) {
				tunnel();
			} else if (fromPrime && MSTunnel.active) {
				// Отметка оказалась лишней (прыжок отменили) — возвращаем обычную страницу.
				stop();
				reveal();
			} else {
				reveal();
			}
			if (typeof original === 'function') return original.apply(this, arguments);
		};

		root.setTimeout(function () {
			if (!MSTunnel.active && !revealed) diag('no signal in ' + HOST_WAIT_MS + ' ms -> default page for now');
			reveal();
		}, HOST_WAIT_MS);
	}

	var MSTunnel = { start: start, stop: stop, active: false, MARKER: MARKER };
	root.MSTunnel = MSTunnel;

	var self = doc.currentScript;
	if (self && self.hasAttribute('data-ms-host')) installHostHook();
})(window, document);
