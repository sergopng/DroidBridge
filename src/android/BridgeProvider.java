package local.droidbridge.helper;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.Binder;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.json.JSONObject;

public final class BridgeProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] arguments, String sort) {
        int uid = Binder.getCallingUid();
        if (uid != 2000 && uid != 0) throw new SecurityException("ADB shell required");
        MatrixCursor rows = new MatrixCursor(new String[] { "payload" });
        List<String> path = uri.getPathSegments();
        if (path.isEmpty()) return rows;
        if (path.get(0).equals("response") && path.size() == 2) {
            SharedPreferences prefs = getContext().getSharedPreferences("responses", 0);
            String result = prefs.getString(path.get(1), null);
            if (result != null) {
                prefs.edit().remove(path.get(1)).commit();
                rows.addRow(new String[] { result });
            }
            return rows;
        }
        PackageManager pm = getContext().getPackageManager();
        if (path.get(0).equals("packages")) {
            for (PackageInfo info : pm.getInstalledPackages(0)) {
                try {
                    JSONObject json = new JSONObject();
                    json.put("id", info.packageName);
                    json.put("name", pm.getApplicationLabel(info.applicationInfo));
                    json.put("version", info.versionName == null ? "" : info.versionName);
                    rows.addRow(new String[] { Base64.encodeToString(json.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP) });
                } catch (Exception ignored) {}
            }
        } else if (path.get(0).equals("icon") && path.size() == 2) {
            try {
                Drawable icon = pm.getApplicationIcon(path.get(1));
                Bitmap bitmap = Bitmap.createBitmap(72, 72, Bitmap.Config.ARGB_8888);
                icon.setBounds(0, 0, 72, 72);
                icon.draw(new Canvas(bitmap));
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
                rows.addRow(new String[] { Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP) });
            } catch (Exception ignored) {}
        }
        return rows;
    }

    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] arguments) { throw new UnsupportedOperationException(); }
}
