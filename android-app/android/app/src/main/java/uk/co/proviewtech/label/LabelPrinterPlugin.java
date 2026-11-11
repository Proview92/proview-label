package uk.co.proviewtech.label;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothSocket;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.net.Uri;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.IBinder;
import android.util.Base64;

import androidx.core.content.ContextCompat;

import recieptservice.com.recieptservice.PrintCallback;
import recieptservice.com.recieptservice.PrinterInterface;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.Set;
import java.util.UUID;

/**
 * Printing for Proview Label:
 *  - the built-in printer of Senraise handhelds (H10P / H10S): a label picture, or ESC/POS bytes, via the device's print service
 *  - any ESC/POS thermal printer over Bluetooth (classic SPP) or the network (raw TCP, usually port 9100)
 * Also passes barcodes from the handheld's hardware scanner to the app ("scan" event).
 */
@CapacitorPlugin(
    name = "LabelPrinter",
    permissions = {
        @Permission(alias = "bluetooth", strings = { Manifest.permission.BLUETOOTH_CONNECT })
    }
)
public class LabelPrinterPlugin extends Plugin {

    private static final UUID SPP = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");

    // ---------- built-in printer (Senraise print service) ----------
    private static final String SR_PKG = "recieptservice.com.recieptservice";
    private static final String SR_SVC = "recieptservice.com.recieptservice.service.PrinterService";
    private volatile PrinterInterface builtin;
    private boolean bound = false;
    private final Object bindLock = new Object();

    private final ServiceConnection conn = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder service) {
            synchronized (bindLock) { builtin = PrinterInterface.Stub.asInterface(service); bindLock.notifyAll(); }
        }
        @Override public void onServiceDisconnected(ComponentName name) { builtin = null; bound = false; }
    };

    private boolean hasBuiltinService() {
        try { getContext().getPackageManager().getPackageInfo(SR_PKG, 0); return true; } catch (Exception e) { return false; }
    }

    private void bindBuiltin() {
        if (bound || !hasBuiltinService()) return;
        Intent i = new Intent();
        i.setClassName(SR_PKG, SR_SVC);
        try { bound = getContext().bindService(i, conn, Context.BIND_AUTO_CREATE); } catch (Exception e) { bound = false; }
    }

    /** Wait (off the UI thread) for the print service to connect. */
    private PrinterInterface awaitBuiltin(long ms) throws Exception {
        if (builtin != null) return builtin;
        bindBuiltin();
        if (!bound) throw new Exception("this device has no built-in printer");
        long end = System.currentTimeMillis() + ms;
        synchronized (bindLock) {
            while (builtin == null && System.currentTimeMillis() < end) bindLock.wait(Math.max(1, end - System.currentTimeMillis()));
        }
        if (builtin == null) throw new Exception("built-in printer did not respond");
        return builtin;
    }

    // ---------- hardware scanner (broadcast "android.scanner.scan", extra "result") ----------
    private final BroadcastReceiver scanReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String code = intent.getStringExtra("result");
            if (code == null || code.trim().isEmpty()) return;
            JSObject o = new JSObject();
            o.put("code", code.trim());
            notifyListeners("scan", o);
        }
    };
    private boolean scanRegistered = false;

    @Override
    public void load() {
        bindBuiltin();
        try {
            ContextCompat.registerReceiver(getContext(), scanReceiver, new IntentFilter("android.scanner.scan"), ContextCompat.RECEIVER_EXPORTED);
            scanRegistered = true;
        } catch (Exception ignored) {}
    }

    @Override
    protected void handleOnDestroy() {
        if (scanRegistered) try { getContext().unregisterReceiver(scanReceiver); } catch (Exception ignored) {}
        if (bound) try { getContext().unbindService(conn); } catch (Exception ignored) {}
        bound = false; builtin = null;
    }

    /** Read-only look at what this handheld's print service offers (for Proview support). Prints nothing, changes nothing. */
    @PluginMethod
    public void printerDiagnostics(PluginCall call) {
        new Thread(() -> {
            StringBuilder o = new StringBuilder();
            final Context ctx = getContext();
            final android.content.pm.PackageManager pm = ctx.getPackageManager();
            o.append("DEVICE ").append(Build.MANUFACTURER).append(' ').append(Build.MODEL).append(" / ").append(Build.DEVICE)
                .append(" · Android ").append(Build.VERSION.RELEASE).append(" (").append(Build.VERSION.SDK_INT).append(") · ").append(Build.DISPLAY).append('\n');
            java.util.List<String> pkgs = new java.util.ArrayList<>();
            pkgs.add(SR_PKG);
            try {
                for (android.content.pm.PackageInfo pi : pm.getInstalledPackages(0)) {
                    String n = pi.packageName.toLowerCase();
                    if (!pkgs.contains(pi.packageName) && (n.contains("print") || n.contains("reciept") || n.contains("receipt") || n.contains("senraise") || n.contains("serial") || n.contains("scanner") || n.contains(".sr.") || n.contains("pos")))
                        pkgs.add(pi.packageName);
                }
            } catch (Exception e) { o.append("list packages: ").append(e).append('\n'); }
            for (String pkg : pkgs) {
                try {
                    android.content.pm.PackageInfo pi = pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SERVICES | android.content.pm.PackageManager.GET_RECEIVERS | android.content.pm.PackageManager.GET_PROVIDERS | android.content.pm.PackageManager.GET_PERMISSIONS);
                    o.append("\nPKG ").append(pkg).append(" v").append(pi.versionName).append(" (").append(pi.versionCode).append(")\n");
                    if (pi.permissions != null) for (android.content.pm.PermissionInfo x : pi.permissions) o.append("  perm ").append(x.name).append('\n');
                    if (pi.receivers != null) for (android.content.pm.ActivityInfo x : pi.receivers) o.append("  rcv ").append(x.name).append(x.exported ? " [exported]" : "").append('\n');
                    if (pi.providers != null) for (android.content.pm.ProviderInfo x : pi.providers) o.append("  prov ").append(x.authority).append(x.exported ? " [exported]" : "").append('\n');
                    if (pi.services != null) for (android.content.pm.ServiceInfo si : pi.services) {
                        o.append("  svc ").append(si.name).append(si.exported ? " [exported]" : "").append(si.permission != null ? " perm=" + si.permission : "");
                        if (si.exported && !pkg.equals(ctx.getPackageName())) o.append(" -> ").append(describeService(ctx, pkg, si.name));
                        o.append('\n');
                    }
                } catch (Exception e) { o.append("\nPKG ").append(pkg).append(": ").append(e.getMessage()).append('\n'); }
            }
            try { PrinterInterface p = awaitBuiltin(3000); o.append("\nprint service version: ").append(p.getServiceVersion()).append('\n'); } catch (Exception e) { o.append("\nprint service: ").append(e.getMessage()).append('\n'); }
            for (String dir : new String[]{"/dev", "/sys/class", "/sys/class/gpio", "/sys/devices/platform"}) {
                try { String[] names = new File(dir).list(); if (names == null) continue; StringBuilder b = new StringBuilder();
                    for (String n : names) { String l = n.toLowerCase(); if (l.contains("print") || l.contains("paper") || l.contains("tty") || l.contains("spi") || l.contains("therm")) b.append(n).append(' '); }
                    if (b.length() > 0) o.append(dir).append(": ").append(b).append('\n');
                } catch (Exception ignored) {}
            }
            o.append("\nAPI of the print service (read by reflection, nothing is called)\n").append(serviceApi(ctx));
            JSObject r = new JSObject(); r.put("text", o.toString()); call.resolve(r);
        }).start();
    }

    /** Exact method signatures and constants of the print service's interfaces. Loads its classes read-only; calls none of them. */
    private String serviceApi(Context ctx) {
        StringBuilder o = new StringBuilder();
        try {
            Context pc = ctx.createPackageContext(SR_PKG, Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);
            ClassLoader cl = pc.getClassLoader();
            String b = "recieptservice.com.recieptservice.";
            String[] names = { b + "PrinterInterface", b + "PrinterInterface$Stub", b + "PrintCallback", b + "PrintCallback$Stub", b + "CallbackBundle", b + "VersionCallback", b + "VersionCallback$Stub",
                b + "Sendlnterface", b + "Sendlnterface$Stub", b + "PSAMCallback", b + "PSAMData", b + "draw.PrinterException", b + "draw.PrinterSet", "com.sr.SrPrinter", b + "tools.PrinterSender", b + "tools.PrinterTransferMgr" };
            for (String n : names) {
                try {
                    Class<?> c = Class.forName(n, false, cl);
                    o.append("\nCLASS ").append(n).append(c.isInterface() ? " (interface)" : "").append(c.getSuperclass() != null ? " extends " + c.getSuperclass().getName() : "");
                    for (Class<?> i : c.getInterfaces()) o.append(" implements ").append(i.getName());
                    o.append('\n');
                    for (java.lang.reflect.Field f : c.getDeclaredFields()) {
                        o.append("  F ").append(java.lang.reflect.Modifier.toString(f.getModifiers())).append(' ').append(f.getType().getName()).append(' ').append(f.getName());
                        if (java.lang.reflect.Modifier.isStatic(f.getModifiers()) && java.lang.reflect.Modifier.isFinal(f.getModifiers()) && (f.getType().isPrimitive() || f.getType() == String.class)) {
                            try { f.setAccessible(true); o.append(" = ").append(String.valueOf(f.get(null))); } catch (Throwable t) { o.append(" = ?"); }
                        }
                        o.append('\n');
                    }
                    for (java.lang.reflect.Method m : c.getDeclaredMethods()) {
                        o.append("  M ").append(java.lang.reflect.Modifier.toString(m.getModifiers())).append(' ').append(m.getReturnType().getName()).append(' ').append(m.getName()).append('(');
                        Class<?>[] ps = m.getParameterTypes(); for (int i = 0; i < ps.length; i++) o.append(i > 0 ? ", " : "").append(ps[i].getName());
                        o.append(")\n");
                    }
                } catch (Throwable t) { o.append("\nCLASS ").append(n).append(": ").append(t).append('\n'); }
            }
        } catch (Throwable t) { o.append("could not load: ").append(t).append('\n'); }
        return o.toString();
    }

    /** Names (method, action and status words) found inside the handheld's print service, read from its installed file. Read-only. */
    private String serviceStrings(android.content.pm.PackageManager pm) {
        java.util.LinkedHashSet<String> a = new java.util.LinkedHashSet<>(), b = new java.util.LinkedHashSet<>(), c = new java.util.LinkedHashSet<>();
        try {
            String apk = pm.getApplicationInfo(SR_PKG, 0).sourceDir;
            java.util.zip.ZipFile z = new java.util.zip.ZipFile(apk);
            java.util.Enumeration<? extends java.util.zip.ZipEntry> en = z.entries();
            while (en.hasMoreElements()) {
                java.util.zip.ZipEntry e = en.nextElement();
                if (!e.getName().matches("classes\\d*\\.dex")) continue;
                java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
                try (InputStream in = z.getInputStream(e)) { byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) > 0) bo.write(buf, 0, n); }
                byte[] d = bo.toByteArray();
                java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(d).order(java.nio.ByteOrder.LITTLE_ENDIAN);
                int count = bb.getInt(56), off = bb.getInt(60);
                for (int i = 0; i < count; i++) {
                    int p = bb.getInt(off + i * 4);
                    int len = 0, shift = 0, x;
                    do { x = d[p++] & 0xff; len |= (x & 0x7f) << shift; shift += 7; } while ((x & 0x80) != 0);
                    if (len < 4 || len > 110) continue;
                    int end = p; while (end < d.length && d[end] != 0) end++;
                    String str = new String(d, p, end - p, java.nio.charset.StandardCharsets.UTF_8);
                    String l = str.toLowerCase();
                    if (str.startsWith("TRANSACTION_")) a.add(str);
                    else if ((l.contains("action") || l.contains("intent") || l.contains("broadcast")) && (l.contains("print") || l.contains("paper") || l.contains("reciept") || l.contains("senraise") || l.contains("sr.") || l.contains("scanner"))) b.add(str);
                    else if (l.startsWith("landroid") || l.startsWith("lcom/google") || l.startsWith("landroidx") || l.startsWith("lkotlin")) continue;
                    else if (l.contains("paper") || l.contains("status") || l.contains("overheat") || l.contains("cover") || l.contains("recieptservice.") || l.contains("senraise") || l.contains("printer") || l.contains("callback") || l.contains("listener")) c.add(str);
                }
            }
            z.close();
        } catch (Exception e) { return "could not read: " + e + "\n"; }
        StringBuilder o = new StringBuilder();
        for (String x : a) o.append(x).append('\n');
        o.append("-- actions\n"); for (String x : b) o.append(x).append('\n');
        o.append("-- status / printer\n"); int n = 0; for (String x : c) { if (o.length() > 70000) break; o.append(x).append('\n'); n++; }
        return o.toString();
    }

    /** Bind for a moment and read only the interface name the service answers with. Calls nothing on it. */
    private String describeService(Context ctx, String pkg, String cls) {
        final String[] out = {"no answer"};
        final Object lock = new Object();
        ServiceConnection c = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName n, IBinder b) { try { out[0] = String.valueOf(b.getInterfaceDescriptor()); } catch (Exception e) { out[0] = "err " + e.getMessage(); } synchronized (lock) { lock.notifyAll(); } }
            @Override public void onServiceDisconnected(ComponentName n) {}
            @Override public void onNullBinding(ComponentName n) { out[0] = "null binding"; synchronized (lock) { lock.notifyAll(); } }
        };
        boolean ok = false;
        try {
            Intent i = new Intent(); i.setClassName(pkg, cls);
            ok = ctx.bindService(i, c, Context.BIND_AUTO_CREATE);
            if (!ok) return "can't bind";
            synchronized (lock) { if ("no answer".equals(out[0])) lock.wait(1500); }
        } catch (Exception e) { return "err " + e.getMessage(); }
        finally { if (ok) try { ctx.unbindService(c); } catch (Exception ignored) {} }
        return out[0];
    }

    @PluginMethod
    public void builtinStatus(PluginCall call) {
        new Thread(() -> {
            JSObject r = new JSObject();
            r.put("installed", hasBuiltinService());
            try {
                PrinterInterface p = awaitBuiltin(3000);
                r.put("available", true);
                try { r.put("version", p.getServiceVersion()); } catch (Exception ignored) {}
            } catch (Exception e) {
                r.put("available", false);
                r.put("reason", e.getMessage());
            }
            call.resolve(r);
        }).start();
    }

    /** image: base64 PNG of the label (preferred) · data: base64 ESC/POS bytes · feed: blank lines after (tear-off space)
     *  result: true = print as one job and wait for the printer's own result (paper out, overheating).
     *  Resolves { reported, code, msg }: reported=false when the print service never answered (older service). */
    @PluginMethod
    public void printBuiltin(PluginCall call) {
        final String image = call.getString("image", null);
        final String data = call.getString("data", null);
        final int feed = call.getInt("feed", 4);
        final int dark = call.getInt("dark", -1);
        final boolean wantResult = Boolean.TRUE.equals(call.getBoolean("result", false));
        new Thread(() -> {
            try {
                PrinterInterface p = awaitBuiltin(4000);
                if (dark >= 0) try { p.setDark(dark); } catch (Exception ignored) {}
                Bitmap bmp = null; byte[] raw = null;
                if (image != null && !image.isEmpty()) {
                    byte[] png = Base64.decode(image, Base64.DEFAULT);
                    bmp = BitmapFactory.decodeByteArray(png, 0, png.length);
                    if (bmp == null) throw new Exception("bad label image");
                } else if (data != null && !data.isEmpty()) raw = Base64.decode(data, Base64.DEFAULT);
                else throw new Exception("nothing to print");

                JSObject r = new JSObject();
                if (!wantResult) {
                    if (bmp != null) p.printBitmap(bmp); else p.printEpson(raw);
                    if (feed > 0) p.nextLine(feed);
                    r.put("reported", false); call.resolve(r); return;
                }
                final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
                final int[] code = {0}; final String[] msg = {null};
                boolean held = false;
                try { held = p.beginWork(); } catch (Exception ignored) {}
                if (bmp != null) p.printBitmap(bmp); else p.printEpson(raw);
                if (feed > 0) p.nextLine(feed);
                p.endWork(new PrintCallback.Stub() {
                    @Override public void onPrintResult(int c, String m) { code[0] = c; msg[0] = m; done.countDown(); }
                });
                boolean got = done.await(15, java.util.concurrent.TimeUnit.SECONDS);
                r.put("reported", got); r.put("held", held);
                if (got) { r.put("code", code[0]); r.put("msg", msg[0] == null ? "" : msg[0]); }
                call.resolve(r);
            } catch (Exception e) {
                call.reject("Print failed: " + e.getMessage(), e);
            }
        }).start();
    }

    private boolean needsBtPermission() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && getPermissionState("bluetooth") != PermissionState.GRANTED;
    }

    private BluetoothAdapter adapter() {
        BluetoothManager m = (BluetoothManager) getContext().getSystemService(Context.BLUETOOTH_SERVICE);
        return m != null ? m.getAdapter() : null;
    }

    @PluginMethod
    public void listPaired(PluginCall call) {
        if (needsBtPermission()) { requestPermissionForAlias("bluetooth", call, "btPermsList"); return; }
        doList(call);
    }

    @PermissionCallback
    private void btPermsList(PluginCall call) {
        if (needsBtPermission()) { call.reject("Bluetooth permission denied"); return; }
        doList(call);
    }

    @SuppressLint("MissingPermission")
    private void doList(PluginCall call) {
        BluetoothAdapter a = adapter();
        if (a == null) { call.reject("This device has no Bluetooth"); return; }
        if (!a.isEnabled()) { call.reject("Bluetooth is turned off"); return; }
        JSArray list = new JSArray();
        Set<BluetoothDevice> bonded = a.getBondedDevices();
        if (bonded != null) for (BluetoothDevice d : bonded) {
            JSObject o = new JSObject();
            o.put("name", d.getName());
            o.put("address", d.getAddress());
            list.put(o);
        }
        JSObject ret = new JSObject();
        ret.put("devices", list);
        call.resolve(ret);
    }

    @PluginMethod
    public void print(PluginCall call) {
        String mode = call.getString("mode", "bluetooth");
        if ("bluetooth".equals(mode) && needsBtPermission()) { requestPermissionForAlias("bluetooth", call, "btPermsPrint"); return; }
        doPrint(call);
    }

    @PermissionCallback
    private void btPermsPrint(PluginCall call) {
        if (needsBtPermission()) { call.reject("Bluetooth permission denied"); return; }
        doPrint(call);
    }

    private void doPrint(final PluginCall call) {
        final String mode = call.getString("mode", "bluetooth");
        final String address = call.getString("address", "");
        final int port = call.getInt("port", 9100);
        final String data = call.getString("data", "");
        if (address == null || address.isEmpty()) { call.reject("No printer address set"); return; }
        final byte[] bytes;
        try { bytes = Base64.decode(data, Base64.DEFAULT); } catch (Exception e) { call.reject("Bad print data"); return; }

        new Thread(() -> {
            try {
                if ("tcp".equals(mode)) printTcp(address, port, bytes);
                else printBluetooth(address, bytes);
                call.resolve();
            } catch (Exception e) {
                call.reject("Print failed: " + e.getMessage(), e);
            }
        }).start();
    }

    private void printTcp(String host, int port, byte[] bytes) throws Exception {
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(host, port), 5000);
            s.setSoTimeout(5000);
            OutputStream out = s.getOutputStream();
            out.write(bytes);
            out.flush();
        }
    }

    @SuppressLint("MissingPermission")
    private void printBluetooth(String mac, byte[] bytes) throws Exception {
        BluetoothAdapter a = adapter();
        if (a == null) throw new Exception("no Bluetooth");
        BluetoothDevice d = a.getRemoteDevice(mac);
        a.cancelDiscovery();
        BluetoothSocket sock = null;
        try {
            sock = d.createRfcommSocketToServiceRecord(SPP);
            sock.connect();
            OutputStream out = sock.getOutputStream();
            // write in chunks – many cheap printers have small buffers
            int chunk = 512;
            for (int i = 0; i < bytes.length; i += chunk) {
                out.write(bytes, i, Math.min(chunk, bytes.length - i));
                out.flush();
                Thread.sleep(20);
            }
            Thread.sleep(300);
        } finally {
            if (sock != null) try { sock.close(); } catch (Exception ignored) {}
        }
    }

    /** Download a newer APK and install it.
     *  Android 12+: asks Android to update without a tap (works once Proview Label installed the current version itself;
     *  otherwise Android shows its Install screen this one time). Older Android: Android's Install screen.
     *  auto=true (background update): never opens Settings; rejects with code PERMISSION instead.
     *  Rejects with code PERMISSION when "Install unknown apps" isn't allowed yet. */
    @PluginMethod
    public void installUpdate(PluginCall call) {
        final String url = call.getString("url", null);
        final boolean auto = Boolean.TRUE.equals(call.getBoolean("auto", false));
        if (url == null || !url.startsWith("https://")) { call.reject("bad update address"); return; }
        final Context ctx = getContext();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !ctx.getPackageManager().canRequestPackageInstalls()) {
            if (!auto) {
                Intent s = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.getPackageName()));
                s.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try { ctx.startActivity(s); } catch (Exception ignored) {}
            }
            call.reject("Allow installs from Proview Label first", "PERMISSION");
            return;
        }
        new Thread(() -> {
            HttpURLConnection c = null;
            File apk = null;
            try {
                File dir = new File(ctx.getCacheDir(), "update"); dir.mkdirs();
                apk = new File(dir, "ProviewLabel.apk"); if (apk.exists()) apk.delete();
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(15000); c.setReadTimeout(60000); c.setInstanceFollowRedirects(true);
                c.setRequestProperty("Cache-Control", "no-cache");
                if (c.getResponseCode() != 200) throw new Exception("download failed (" + c.getResponseCode() + ")");
                try (InputStream in = c.getInputStream(); FileOutputStream out = new FileOutputStream(apk)) {
                    byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                }
                if (apk.length() < 100000) throw new Exception("download incomplete");
            } catch (Exception e) {
                call.reject(e.getMessage() != null ? e.getMessage() : "update failed", e);
                return;
            } finally { if (c != null) c.disconnect(); }
            try {
                sessionInstall(ctx, apk);
                JSObject r = new JSObject(); r.put("silent", Build.VERSION.SDK_INT >= 31); call.resolve(r);
            } catch (Exception e) {
                // the package installer route isn't available: Android's classic Install screen, as before
                UpdateReceiver.classicInstall(ctx, apk);
                JSObject r = new JSObject(); r.put("silent", false); call.resolve(r);
            }
        }).start();
    }

    private static void sessionInstall(Context ctx, File apk) throws Exception {
        android.content.pm.PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
        android.content.pm.PackageInstaller.SessionParams p =
            new android.content.pm.PackageInstaller.SessionParams(android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        p.setAppPackageName(ctx.getPackageName());
        if (Build.VERSION.SDK_INT >= 31) p.setRequireUserAction(android.content.pm.PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED);
        int id = pi.createSession(p);
        try (android.content.pm.PackageInstaller.Session s = pi.openSession(id)) {
            try (InputStream in = new java.io.FileInputStream(apk); OutputStream out = s.openWrite("base.apk", 0, apk.length())) {
                byte[] buf = new byte[65536]; int n; while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                s.fsync(out);
            }
            Intent cb = new Intent(ctx, UpdateReceiver.class).setAction(UpdateReceiver.ACTION_STATUS).putExtra(UpdateReceiver.EXTRA_APK, apk.getAbsolutePath());
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? android.app.PendingIntent.FLAG_MUTABLE : 0);
            android.app.PendingIntent pend = android.app.PendingIntent.getBroadcast(ctx, id, cb, flags);
            s.commit(pend.getIntentSender());
        }
    }
}
