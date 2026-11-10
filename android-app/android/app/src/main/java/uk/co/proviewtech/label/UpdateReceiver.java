package uk.co.proviewtech.label;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.net.Uri;
import android.os.Build;
import android.util.Log;
import androidx.core.content.FileProvider;
import java.io.File;

/**
 * App updates (see LabelPrinterPlugin.installUpdate):
 *  - ACTION_STATUS: Android's answer to an install. If it needs a tap (Android 11 and older, or the first update
 *    after the app was installed some other way) it shows Android's Install screen. If the install failed it falls
 *    back to the classic install screen for the downloaded file.
 *  - MY_PACKAGE_REPLACED: the update is in; open the app again (Android may not allow this on every device).
 */
public class UpdateReceiver extends BroadcastReceiver {
    static final String ACTION_STATUS = "uk.co.proviewtech.label.UPDATE_STATUS";
    static final String EXTRA_APK = "apk";
    private static final String TAG = "ProviewUpdate";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent.getAction();
        if (Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) { openApp(ctx); return; }
        if (!ACTION_STATUS.equals(action)) return;
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try { ctx.startActivity(confirm); } catch (Exception e) { Log.w(TAG, "can't show installer", e); }
            }
        } else if (status == PackageInstaller.STATUS_SUCCESS) {
            openApp(ctx);
        } else if (status != PackageInstaller.STATUS_FAILURE_ABORTED) {
            Log.w(TAG, "update failed: " + status + " " + intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
            String path = intent.getStringExtra(EXTRA_APK);
            if (path != null && new File(path).exists()) classicInstall(ctx, new File(path));
        }
    }

    static void classicInstall(Context ctx, File apk) {
        try {
            Uri uri = FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".fileprovider", apk);
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
        } catch (Exception e) { Log.w(TAG, "classic install failed", e); }
    }

    private static void openApp(Context ctx) {
        try {
            Intent i = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            if (i != null) { i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); ctx.startActivity(i); }
        } catch (Exception e) { Log.w(TAG, "can't reopen after update", e); }
    }
}
