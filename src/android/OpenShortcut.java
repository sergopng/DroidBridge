package local.droidbridge.helper;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

public final class OpenShortcut extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String name = getIntent().getStringExtra("package");
        if (name != null && !name.equals(getPackageName())) {
            Intent intent = getPackageManager().getLaunchIntentForPackage(name);
            if (intent != null) {
                try { startActivity(intent); } catch (RuntimeException ignored) {}
            }
        }
        finish();
    }
}
