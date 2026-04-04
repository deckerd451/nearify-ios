import Foundation
import Supabase

final class BeaconRegistryService {
    
    static let shared = BeaconRegistryService()
    
    private let supabase = AppEnvironment.shared.supabaseClient
    private let cacheKey = "beacon_registry_cache"
    private let refreshInterval: TimeInterval = 6 * 60 * 60 // 6 hours
    
    var cache = BeaconCache()
    
    private init() {
        loadCacheFromDisk()
    }
    
    // MARK: - Public API
    
    /// Fetch active beacons and update cache.
    /// NOTE: The public.beacons table may not exist in all environments.
    /// Fails gracefully — returns empty cache if the table is missing.
    func refreshBeacons() async throws {
        
        do {
            let beacons: [Beacon] = try await supabase
                .from("beacons")
                .select()
                .eq("is_active", value: true)
                .execute()
                .value
            
            cache.beacons = Dictionary(
                uniqueKeysWithValues: beacons.map { ($0.beaconKey, $0) }
            )
            
            cache.lastRefreshed = Date()
            
            saveCacheToDisk()
            
            #if DEBUG
            print("[BeaconRegistry] ✅ Refreshed \(beacons.count) active beacons")
            #endif
        } catch {
            let message = String(describing: error)
            if message.contains("PGRST") || message.contains("relation") || message.contains("does not exist") {
                print("[BeaconRegistry] ⚠️ public.beacons table not available — using empty cache")
                cache.beacons = [:]
                cache.lastRefreshed = Date()
                saveCacheToDisk()
            } else {
                print("[BeaconRegistry] ❌ Beacon refresh failed: \(error)")
                throw error
            }
        }
    }
    
    /// Get beacon by beacon_key from cache
    func getBeacon(forKey beaconKey: String) -> Beacon? {
        return cache.beacons[beaconKey]
    }
    
    /// Check if cache needs refresh (6 hours old)
    func needsRefresh() -> Bool {
        return Date().timeIntervalSince(cache.lastRefreshed) > refreshInterval
    }
    
    /// Force refresh if needed
    func refreshIfNeeded() async throws {
        if needsRefresh() {
            try await refreshBeacons()
        }
    }
    
    // MARK: - Persistence
    
    private func loadCacheFromDisk() {
        
        guard
            let data = UserDefaults.standard.data(forKey: cacheKey),
            let decoded = try? JSONDecoder().decode(BeaconCache.self, from: data)
        else {
            return
        }
        
        cache = decoded
        
        #if DEBUG
        print("✅ Loaded \(cache.beacons.count) beacons from cache")
        #endif
    }
    
    private func saveCacheToDisk() {
        
        guard let data = try? JSONEncoder().encode(cache) else { return }
        
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
