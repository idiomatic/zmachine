# The Zork II plan for play.py: steps and the text each must print.
STORY = 'games/zork2.r63-860811.z3'
W = lambda d: f'walk through {d} wall'
STEPS = [
    # The gazebo's tea things.
    ('do', ['take sword and lantern', 'turn on lantern', 'south', 'south', 'south'], 'Great Cavern'),
    ('do', ['southwest', 'south', 'southeast', 'enter gazebo'], 'Gazebo'),
    ('do', ['take teapot, mat, opener and matchbook'], 'matchbook: Taken'),
    ('do', ['out', 'south', 'south', 'west'], 'Carousel Room'),
    # The riddle and the necklace.
    ('go', 'Riddle Room'),
    ('do', ['answer "a well"', 'east', 'take necklace', 'west', 'down'], ('Taken', 'Carousel Room')),
    # Water, the key under the door and the blue sphere.
    ('go', 'Marble Hall'),
    ('do', ['north', 'fill teapot with water', 'north', 'up'], ('full of water', 'Tiny Room')),
    ('do', ['put mat under door', 'open lid', 'put opener in keyhole', 'pull mat'], 'falls from it'),
    ('do', ['take key', 'take opener', 'unlock door with key', 'open door', 'north'], 'Dreary Room'),
    ('do', ['drop opener and key', 'take sphere'], 'Taken'),
    # The dragon, the ruby, the statuette and the princess.
    ('do', ['south', 'down', 'west', 'north'], 'Dragon Room'),
    ('do', ['hit dragon with sword', 'south'], 'The dragon follows'),
    ('do', ['hit dragon with sword', 'south'], 'The dragon follows'),
    ('do', ['hit dragon with sword', 'west'], 'dies'),
    ('do', ['west', 'take ruby', 'east', 'east', 'north', 'north', 'north'], ('Taken', "Dragon's Lair")),
    ('until', ['open chest'], 'statuette', 3),
    ('do', ['take statuette', 'south', 'east', 'east', 'down', 'south', 'south'], ('Taken', 'Carousel Room')),
    ('go', 'Topiary'),
    ('do', ['north', 'north', 'enter gazebo'], 'Gazebo'),
    ('until', ['wait'], 'hands you the key', 30),
    ('do', ['drop rose, statuette, ruby, necklace and sphere', 'out', 'south', 'south', 'west'], 'Carousel Room'),
    # The well, the cakes, the candy, the robot and the red sphere.
    ('go', 'Riddle Room'),
    ('do', ['east', 'east', 'enter bucket', 'pour water in bucket', 'get out of bucket', 'east'], 'Tea Room'),
    ('do', ['take red cake, orange cake and blue cake', 'eat green cake', 'east', 'throw red cake in pool',
            'take candies', 'west', 'eat blue cake', 'drop orange cake', 'northwest'], ('candies', 'Low Room')),
    ('do', ['robot, east', 'east'], 'Machine Room'),
    ('until', ['robot, push triangular button'], 'thump', 4),
    ('do', ['robot, south', 'south', 'take sphere', 'robot, lift cage', 'take sphere', 'north'], 'Taken.'),
    ('do', ['west'], 'Low Room'),
    ('do', ['southeast'], 'Tea Room'),
    ('do', ['west', 'enter bucket', 'fill teapot with water', 'get out of bucket', 'west', 'west', 'down'],
     'steel box'),
    # The violin, the string, the lizard and the Wizard's workshop.
    ('do', ['open box', 'take violin', 'southwest', 'take string', 'southwest', 'give candy to lizard',
            'unlock door with gold key', 'open door', 'south'], "Wizard's Workshop"),
    ('do', ['drop violin, key and teapot', 'north', 'north', 'northeast', 'east', 'north', 'north', 'enter gazebo',
            'take sphere and newspaper', 'out', 'south', 'south', 'west', 'southwest', 'southwest', 'south', 'west',
            'west'], 'Aquarium Room'),
    # The clear sphere, the black sphere and the demon.
    ('do', ['throw sword at aquarium'], 'clear crystal sphere'),
    ('do', ['take clear sphere', 'east', 'put red sphere on ruby stand', 'put blue sphere on sapphire stand',
            'put clear sphere on diamond stand', 'take black sphere', 'south', 'put black sphere in circle'],
     'demon'),
    # The volcano: the zorkmid, the stamp and the crown.
    ('do', ['north', 'east', 'north', 'north', 'northeast', 'north', 'take brick', 'south', 'northwest', 'west',
            'west', 'south', 'open receptacle', 'put newspaper in receptacle', 'enter basket', 'light match',
            'light newspaper with match', 'wait', 'wait', 'west', 'tie wire to hook', 'get out of basket',
            'take zorkmid', 'south', 'open purple book', 'take stamp', 'north', 'enter basket', 'untie wire',
            'wait', 'wait', 'wait', 'west', 'tie wire to hook', 'get out of basket', 'south',
            'put string in brick', 'put brick in hole', 'light match', 'light string with match', 'north',
            'south', 'take crown', 'north', 'enter basket', 'untie wire', 'close receptacle'] + ['wait'] * 7 +
     ['get out of basket', 'north'], ('Lava Room',)),
    # The bank: the portrait and the bills.
    ('do', ['east', 'east', 'north', 'north', 'west', 'west', 'northeast', 'east', 'south', 'take portrait',
            'north', W('north'), W('south'), W('north'), 'take bills', W('north'), 'drop portrait and bills',
            'west', 'west', 'take portrait and bills', W('north'), 'south', 'east'], 'Fresco Room'),
    # The demon's fee and the wand.
    ('do', ['east', 'south', 'south', 'southeast', 'east', 'north', 'north', 'enter gazebo', 'drop matchbook',
            'take statuette, necklace and ruby', 'out', 'south', 'south', 'west', 'southwest', 'southwest', 'south',
            'west', 'south', 'give bills to demon', 'give portrait to demon', 'give crown to demon',
            'give stamp to demon', 'give zorkmid to demon', 'give statuette to demon', 'give necklace to demon',
            'give ruby to demon', 'north', 'east', 'take violin and key', 'west', 'south', 'give violin to demon',
            'give key to demon', 'demon, give me the wand', 'take wand'], 'lays it before you'),
    # The menhir, the collar, Cerberus and the crypt.
    ('do', ['north', 'east', 'north', 'north', 'northeast', 'south', 'wave wand at menhir', 'say "float" to menhir',
            'southwest', 'take collar', 'northeast', 'south', 'down'], 'Oddly-angled Room'),
    ('odd',),
    ('do', ['put collar on dog', 'east', 'open door', 'south', 'close door', 'turn off lamp', 'open secret door',
            'south'], 'Your score would be 400'),
]
