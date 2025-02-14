extension String {
    func hasPrefix(in array: [String]) -> Bool {
        for item in array {
            if self.hasPrefix(item) {
                return true
            }
        }
        return false
    }
}