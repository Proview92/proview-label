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

    /** image: base64 PNG of the label (preferred) · data: base64 ESC/POS bytes · feed: blank lines after (tear-off space) */
    @PluginMethod
    public void printBuiltin(PluginCall call) {
        final String image = call.getString("image", null);
        final String data = call.getString("data", null);
        final int feed = call.getInt("feed", 4);
        final int dark = call.getInt("dark", -1);
        new Thread(() -> {
            try {
                PrinterInterface p = awaitBuiltin(4000);
                if (dark >= 0) try { p.setDark(dark); } catch (Exception ignored) {}
                if (image != null && !image.isEmpty()) {
                    byte[] png = Base64.decode(image, Base64.DEFAULT);
                    Bitmap bmp = BitmapFactory.decodeByteArray(png, 0, png.length);
                    if (bmp == null) throw new Exception("bad label image");
                    p.printBitmap(bmp);
                } else if (data != null && !data.isEmpty()) {
                    p.printEpson(Base64.decode(data, Base64.DEFAULT));
                } else throw new Exception("nothing to print");
                if (feed > 0) p.nextLine(feed);
                call.resolve();
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
