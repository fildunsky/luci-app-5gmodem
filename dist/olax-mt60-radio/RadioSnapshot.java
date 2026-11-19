import android.os.IBinder;
import android.os.SystemClock;
import android.telephony.CellIdentityLte;
import android.telephony.CellInfo;
import android.telephony.CellInfoLte;
import android.telephony.CellSignalStrengthLte;
import android.telephony.ServiceState;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.Arrays;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** Read the stock Android radio on the MT60 without taking over the modem transport. */
public final class RadioSnapshot {
    private static final String CALLER = "com.android.shell";
    private static final Pattern CSQ = Pattern.compile("(?m)^\\+CSQ:[ \\t]*([0-9]{1,2})[ \\t]*,[ \\t]*[0-9]{1,2}[ \\t]*\\r?$");
    // Response fields: valid, radio technology (4 = LTE), EARFCN and band.
    private static final Pattern ESCELLINFO = Pattern.compile(
        "(?m)^\\+ESCELLINFO:[ \\t]*1[ \\t]*,[ \\t]*4[ \\t]*,"
        + "[ \\t]*([0-9]{1,6})[ \\t]*,[ \\t]*([0-9]{1,2})[ \\t]*\\r?$");
    private static final Pattern EPBSE = Pattern.compile(
        "(?m)^\\+EPBSE:[ \\t]*([0-9]+(?:[ \\t]*,[ \\t]*[0-9]+){9})[ \\t]*\\r?$");
    private static final Pattern BAND_REQUEST = Pattern.compile(
        "([0-9]{1,9})\\|([0-9]{1,12})\\|((?:default|[0-9]{1,4}(?: [0-9]{1,4}){0,15})?)"
        + "\\|((?:default|[0-9]{1,3}(?: [0-9]{1,3}){0,15})?)");
    // Zero entries are undocumented bits. Preserve them on writes.
    private static final int[] GSM = {0, 900, 0, 1800, 1900, 0, 0, 850};
    private static final int[] UMTS = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 0, 0, 0, 0, 0, 19};
    private final Method service;
    private final Method asPhone;
    private final Method allCells;
    private final Method serviceState;
    private final Method oemRequest;
    private static final class AtSample {
        volatile Integer csq;
        volatile JSONObject servingCarrier;
    }

    private FutureTask<Void> pendingAt;
    private AtSample pendingSample;
    private long atStarted;
    private final Method defaultDataSubscription;
    private final Method asSubscriptions;
    private final Method subscriptionInfo;
    private final Method systemProperty;
    private final Method earfcn;
    private final Method rsrq;
    private final Method isCa;
    private final Method dataRegistration;

    private RadioSnapshot() throws Exception {
        service = Class.forName("android.os.ServiceManager").getMethod("getService", String.class);
        asPhone = Class.forName("com.android.internal.telephony.ITelephony$Stub")
            .getMethod("asInterface", IBinder.class);
        Class<?> phone = Class.forName("com.android.internal.telephony.ITelephony");
        allCells = phone.getMethod("getAllCellInfo", String.class);
        oemRequest = phone.getMethod("invokeOemRilRequestRaw", byte[].class, byte[].class);
        serviceState = phone.getMethod("getServiceStateForSubscriber", int.class, String.class);
        defaultDataSubscription = SubscriptionManager.class.getMethod("getDefaultDataSubscriptionId");
        asSubscriptions = Class.forName("com.android.internal.telephony.ISub$Stub")
            .getMethod("asInterface", IBinder.class);
        subscriptionInfo = Class.forName("com.android.internal.telephony.ISub")
            .getMethod("getActiveSubscriptionInfo", int.class, String.class);
        systemProperty = Class.forName("android.os.SystemProperties").getMethod("get", String.class);
        earfcn = CellIdentityLte.class.getMethod("getEarfcn");
        rsrq = CellSignalStrengthLte.class.getMethod("getRsrq");
        isCa = ServiceState.class.getMethod("isUsingCarrierAggregation");
        dataRegistration = ServiceState.class.getMethod("getDataRegState");
    }

    private String property(String name) throws Exception {
        return (String) systemProperty.invoke(null, name);
    }

    private static void number(JSONObject object, String key, int value, int min, int max) throws Exception {
        if (value >= min && value <= max) object.put(key, value);
    }

    private JSONObject lteCell(CellInfoLte cell) throws Exception {
        CellIdentityLte id = cell.getCellIdentity();
        CellSignalStrengthLte signal = cell.getCellSignalStrength();
        JSONObject row = new JSONObject();
        row.put("serving", cell.isRegistered() ? 1 : 0);
        long observed = cell.getTimeStamp();
        if (observed > 0 && observed <= SystemClock.elapsedRealtimeNanos())
            row.put("seen_uptime", observed / 1_000_000_000L);
        number(row, "pci", id.getPci(), 0, 503);
        number(row, "earfcn", (Integer) earfcn.invoke(id), 0, 262143);
        number(row, "rsrp", signal.getDbm(), -156, -31);
        number(row, "level", signal.getLevel(), 0, 4);
        number(row, "rsrq", (Integer) rsrq.invoke(signal), -43, 0);
        if (cell.isRegistered()) {
            number(row, "ci", id.getCi(), 0, 268435454);
            number(row, "tac", id.getTac(), 0, 65534);
            number(row, "ta", signal.getTimingAdvance(), 0, 1282);
        }
        return row;
    }

    private String at(Object phone, String command) throws Exception {
        byte[] answer = new byte[256];
        int count = (Integer) oemRequest.invoke(phone, command.getBytes(StandardCharsets.US_ASCII), answer);
        return count > 0 && count <= answer.length ? new String(answer, 0, count, StandardCharsets.US_ASCII) : "";
    }

    private Integer readCsq(Object phone) throws Exception {
        Matcher response = CSQ.matcher(at(phone, "AT+CSQ"));
        if (!response.find()) return null;
        int value = Integer.parseInt(response.group(1));
        return value <= 31 ? value : null;
    }

    private JSONObject readServingCarrier(Object phone) throws Exception {
        Matcher response = ESCELLINFO.matcher(at(phone, "AT+ESCELLINFO?"));
        if (!response.find()) return null;
        int band = Integer.parseInt(response.group(2));
        if (band == 0) return null;
        return new JSONObject().put("band", band)
            .put("earfcn", Integer.parseInt(response.group(1)));
    }

    private String[] bandTuple(Object phone, String command) throws Exception {
        Matcher result = EPBSE.matcher(at(phone, command));
        if (!result.find()) throw new IllegalStateException("band masks unavailable");
        return result.group(1).replaceAll("[ \\t]", "").split(",");
    }

    private static JSONArray bandList(String value, int[] map) {
        long mask = Long.parseLong(value);
        JSONArray list = new JSONArray();
        for (int i = 0; i < map.length; i++) {
            if (map[i] != 0 && (mask & (1L << i)) != 0) list.put(map[i]);
        }
        return list;
    }

    private static String bandSelection(String current, String supported, String selection, int[] map) {
        if (selection.isEmpty()) return current;
        long known = 0;
        long allowed = Long.parseLong(supported);
        for (int i = 0; i < map.length; i++) {
            if (map[i] != 0) known |= 1L << i;
        }
        long selected = selection.equals("default") ? allowed & known : 0;
        if (!selection.equals("default")) {
            for (String band : selection.split(" ")) {
                long bit = 0;
                for (int i = 0; i < map.length; i++) {
                    if (map[i] != 0 && map[i] == Integer.parseInt(band)) bit = 1L << i;
                }
                if ((bit & allowed) == 0) throw new IllegalArgumentException("unsupported band");
                selected |= bit;
            }
        }
        if (selected == 0) throw new IllegalArgumentException("no supported band");
        return Long.toString((Long.parseLong(current) & ~known) | selected);
    }

    private JSONObject bands(String request) throws Exception {
        Matcher args = BAND_REQUEST.matcher(request);
        if (!args.matches()) return new JSONObject();
        JSONObject out = new JSONObject().put("id", args.group(1)).put("ok", false);
        long age = SystemClock.elapsedRealtime() / 1000 - Long.parseLong(args.group(2));
        if (age < 0 || age > 10) return out.put("error", "expired");
        Object phone = asPhone.invoke(null, service.invoke(null, "phone"));
        try {
            String[] supported = bandTuple(phone, "AT+EPBSE=?");
            String[] original = bandTuple(phone, "AT+EPBSE?");
            String[] next = original.clone();
            next[0] = bandSelection(original[0], supported[0], args.group(3), GSM);
            next[1] = bandSelection(original[1], supported[1], args.group(4), UMTS);
            if (!Arrays.equals(next, original)) {
                boolean applied = false;
                try {
                    String response = at(phone, "AT+EPBSE=" + String.join(",", next));
                    applied = response.trim().endsWith("OK") &&
                        Arrays.equals(next, bandTuple(phone, "AT+EPBSE?"));
                } catch (Exception ignored) {
                    // Verify the original state below even if the modem stopped responding.
                }
                if (!applied) {
                    try {
                        at(phone, "AT+EPBSE=" + String.join(",", original));
                        if (Arrays.equals(original, bandTuple(phone, "AT+EPBSE?")))
                            return out.put("error", "write_not_confirmed");
                    } catch (Exception ignored) {}
                    return out.put("error", "restore_not_confirmed");
                }
            }
            return out.put("ok", true)
                .put("supported2g", bandList(supported[0], GSM)).put("enabled2g", bandList(next[0], GSM))
                .put("supported3g", bandList(supported[1], UMTS)).put("enabled3g", bandList(next[1], UMTS));
        } catch (IllegalArgumentException e) {
            return out.put("error", "invalid_bands");
        } catch (Exception e) {
            return out.put("error", "radio_unavailable");
        }
    }

    private AtSample sampleAt(Object phone, boolean lte) throws InterruptedException {
        if (pendingAt == null) {
            AtSample sample = new AtSample();
            pendingSample = sample;
            atStarted = SystemClock.elapsedRealtime();
            pendingAt = new FutureTask<>(() -> {
                try {
                    sample.csq = readCsq(phone);
                } catch (Exception ignored) {}
                if (lte) {
                    try {
                        sample.servingCarrier = readServingCarrier(phone);
                    } catch (Exception ignored) {}
                }
                return null;
            });
            Thread worker = new Thread(pendingAt, "mt60-radio-at");
            worker.setDaemon(true);
            worker.start();
        }
        AtSample sample = pendingSample;
        try {
            pendingAt.get(600, TimeUnit.MILLISECONDS);
            pendingAt = null;
        } catch (TimeoutException ignored) {
            // Reuse the outstanding request so a stalled RIL cannot queue more AT work.
        } catch (ExecutionException ignored) {
            pendingAt = null;
        }
        return SystemClock.elapsedRealtime() - atStarted <= 12000 ? sample : new AtSample();
    }

    private JSONObject sample() throws Exception {
        JSONObject out = new JSONObject();
        Object phone = asPhone.invoke(null, service.invoke(null, "phone"));
        if (phone == null) throw new IllegalStateException("phone service unavailable");
        int sub = (Integer) defaultDataSubscription.invoke(null);
        ServiceState state = (ServiceState) serviceState.invoke(phone, sub, CALLER);
        if (state != null) {
            out.put("registered", (Integer) dataRegistration.invoke(state) == ServiceState.STATE_IN_SERVICE);
            out.put("roaming", state.getRoaming());
            out.put("aggregation", (Boolean) isCa.invoke(state));
            out.put("operator", state.getOperatorAlphaLong());
            out.put("plmn", state.getOperatorNumeric());
        }
        out.put("rat", property("gsm.network.type"));
        out.put("sim", property("gsm.sim.state"));
        if ("READY".equals(out.optString("sim"))) {
            try {
                Object binder = service.invoke(null, "isub");
                Object subscriptions = asSubscriptions.invoke(null, binder);
                SubscriptionInfo info = (SubscriptionInfo) subscriptionInfo.invoke(subscriptions, sub, CALLER);
                if (info != null) out.put("iccid", info.getIccId());
            } catch (ReflectiveOperationException ignored) {
                // LTE metrics remain available when the SIM identity is restricted.
            }
        }
        if (out.optBoolean("registered") && "LTE".equals(out.optString("rat"))) {
            out.put("primary_band", property("sys.conn.bandPcell"));
            out.put("secondary_bands", new JSONArray()
                .put(property("sys.conn.bandScell0")).put(property("sys.conn.bandScell1"))
                .put(property("sys.conn.bandScell2")));
            out.put("sinr_tenths", property("sys.conn.snrPcell"));
            out.put("rsrp", property("sys.conn.rsrpPcell"));
            out.put("rsrq", property("sys.conn.rsrqPcell"));
        }
        JSONArray cells = new JSONArray();
        Object value = allCells.invoke(phone, CALLER);
        if (value instanceof List<?>) {
            for (Object cell : (List<?>) value) {
                if (cell instanceof CellInfoLte) cells.put(lteCell((CellInfoLte) cell));
            }
        }
        out.put("cells", cells);
        if (out.optBoolean("registered")) {
            boolean lte = "LTE".equals(out.optString("rat"));
            AtSample atSample = sampleAt(phone, lte);
            if (atSample.csq != null) out.put("csq", atSample.csq);
            if (lte && atSample.servingCarrier != null)
                out.put("serving_carrier", atSample.servingCarrier);
        }
        out.put("sampled_uptime", SystemClock.elapsedRealtime() / 1000);
        return out;
    }

    public static void main(String[] args) throws Exception {
        RadioSnapshot radio = new RadioSnapshot();
        if (args.length == 2 && "bands".equals(args[0])) {
            System.out.println(radio.bands(args[1]));
            return;
        }
        do {
            try {
                System.out.println(radio.sample());
            } catch (Exception e) {
                System.err.println("MT60 radio sample unavailable: " + e.getClass().getSimpleName());
            }
            if (args.length == 0) return;
            if (System.out.checkError()) return;
            Thread.sleep(6000);
        } while (true);
    }
}
